#!/usr/bin/env bash
# Copyright 2026 Optiqor contributors
# SPDX-License-Identifier: Apache-2.0
#
# Runtime validation for the installed kerno systemd service.
# This intentionally uses the real systemd paths so CI catches packaging/unit
# drift that unit tests and direct `kerno start` smoke tests cannot see.

set -Eeuo pipefail

cd "$(dirname "$0")/.."

SERVICE_NAME="${KERNO_SYSTEMD_SERVICE:-kerno}"
UNIT_PATH="${KERNO_SYSTEMD_UNIT_PATH:-/etc/systemd/system/${SERVICE_NAME}.service}"
DROPIN_DIR="${KERNO_SYSTEMD_DROPIN_DIR:-/etc/systemd/system/${SERVICE_NAME}.service.d}"
DROPIN_PATH="${DROPIN_DIR}/runtime-validation.conf"
CONFIG_DIR="${KERNO_CONFIG_DIR:-/etc/kerno}"
CONFIG_PATH="${CONFIG_DIR}/config.yaml"
INSTALL_BIN="${KERNO_INSTALL_BIN:-/usr/local/bin/kerno}"
SOURCE_BIN="${KERNO_SOURCE_BIN:-bin/kerno}"
HEALTH_PORT="${KERNO_TEST_HEALTH_PORT:-19090}"
HEALTH_URL="http://127.0.0.1:${HEALTH_PORT}/healthz"
JOURNAL_LINES="${KERNO_TEST_JOURNAL_LINES:-200}"
BACKUP_DIR=""
DIAGNOSTICS_ENABLED=false
CAN_SUDO=false

log() {
    printf '==> %s\n' "$*"
}

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

dump_diagnostics() {
    local exit_code=$?
    if [[ "$exit_code" -eq 0 ]]; then
        return
    fi
    if [[ "$DIAGNOSTICS_ENABLED" != true ]]; then
        return
    fi

    printf '\n===== systemctl status %s =====\n' "$SERVICE_NAME" >&2
    sudo -n systemctl status "$SERVICE_NAME" --no-pager -l >&2 || true

    printf '\n===== journalctl -u %s =====\n' "$SERVICE_NAME" >&2
    sudo -n journalctl -u "$SERVICE_NAME" --no-pager -n "$JOURNAL_LINES" >&2 || true
}

cleanup() {
    if [[ "$CAN_SUDO" != true ]]; then
        return
    fi

    sudo systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    sudo systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
    sudo rm -f "$UNIT_PATH" "$DROPIN_PATH"
    sudo rmdir "$DROPIN_DIR" >/dev/null 2>&1 || true
    sudo rm -f "$INSTALL_BIN"
    sudo rm -f "$CONFIG_PATH"

    if [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]]; then
        if [[ -f "$BACKUP_DIR/kerno" ]]; then
            sudo install -D -m 0755 "$BACKUP_DIR/kerno" "$INSTALL_BIN"
        fi
        if [[ -f "$BACKUP_DIR/kerno.service" ]]; then
            sudo install -D -m 0644 "$BACKUP_DIR/kerno.service" "$UNIT_PATH"
        fi
        if [[ -f "$BACKUP_DIR/config.yaml" ]]; then
            sudo install -D -m 0644 "$BACKUP_DIR/config.yaml" "$CONFIG_PATH"
        fi
        sudo rm -rf "$BACKUP_DIR"
    fi

    sudo rmdir "$CONFIG_DIR" >/dev/null 2>&1 || true
    sudo systemctl daemon-reload >/dev/null 2>&1 || true
    sudo systemctl reset-failed "$SERVICE_NAME" >/dev/null 2>&1 || true
}

remove_current_install() {
    sudo systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    sudo systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
    sudo rm -f "$UNIT_PATH" "$DROPIN_PATH" "$INSTALL_BIN" "$CONFIG_PATH"
    sudo rmdir "$DROPIN_DIR" >/dev/null 2>&1 || true
    sudo rmdir "$CONFIG_DIR" >/dev/null 2>&1 || true
    sudo systemctl daemon-reload >/dev/null 2>&1 || true
    sudo systemctl reset-failed "$SERVICE_NAME" >/dev/null 2>&1 || true
}

trap dump_diagnostics ERR
trap cleanup EXIT

require_cmd curl
require_cmd jq
require_cmd sudo
require_cmd systemctl
require_cmd journalctl

sudo -n true 2>/dev/null || fail "passwordless sudo is required for systemd runtime validation"
CAN_SUDO=true
DIAGNOSTICS_ENABLED=true

if [[ "$(uname -s)" != "Linux" ]]; then
    fail "systemd runtime validation requires Linux"
fi

if ! systemctl --version >/dev/null 2>&1; then
    fail "systemctl is present but unusable in this environment"
fi

if [[ ! -x "$SOURCE_BIN" ]]; then
    log "building $SOURCE_BIN"
    make build
fi

[[ -x "$SOURCE_BIN" ]] || fail "expected built binary at $SOURCE_BIN"
[[ -f deploy/systemd/kerno.service ]] || fail "missing deploy/systemd/kerno.service"
[[ -f deploy/systemd/kerno.yaml ]] || fail "missing deploy/systemd/kerno.yaml"

BACKUP_DIR="$(mktemp -d)"
[[ -f "$INSTALL_BIN" ]] && sudo cp "$INSTALL_BIN" "$BACKUP_DIR/kerno"
[[ -f "$UNIT_PATH" ]] && sudo cp "$UNIT_PATH" "$BACKUP_DIR/kerno.service"
[[ -f "$CONFIG_PATH" ]] && sudo cp "$CONFIG_PATH" "$BACKUP_DIR/config.yaml"

log "installing kerno binary, config, and systemd unit"
remove_current_install
sudo install -D -m 0755 "$SOURCE_BIN" "$INSTALL_BIN"
sudo install -D -m 0644 deploy/systemd/kerno.service "$UNIT_PATH"
sudo install -D -m 0644 deploy/systemd/kerno.yaml "$CONFIG_PATH"
sudo install -d -m 0755 "$DROPIN_DIR"
sudo tee "$DROPIN_PATH" >/dev/null <<EOF
[Service]
Environment=KERNO_PROMETHEUS_ADDR=:${HEALTH_PORT}
Environment=KERNO_LOG_FORMAT=json
EOF

[[ -f "$UNIT_PATH" ]] || fail "unit file was not installed at $UNIT_PATH"

log "reloading systemd and starting ${SERVICE_NAME}"
sudo systemctl daemon-reload
sudo systemctl start "$SERVICE_NAME"

log "waiting for ${SERVICE_NAME} to become active"
active=""
for _ in {1..20}; do
    active="$(systemctl is-active "$SERVICE_NAME" || true)"
    if [[ "$active" == "active" ]]; then
        break
    fi
    sleep 0.5
done
[[ "$active" == "active" ]] || fail "expected ${SERVICE_NAME} to be active, got ${active:-unknown}"

log "waiting for health endpoint ${HEALTH_URL}"
health_body=""
http_code=""
for _ in {1..20}; do
    response="$(curl -fsS -w '\n%{http_code}' "$HEALTH_URL" 2>/tmp/kerno-health-curl.err || true)"
    http_code="$(printf '%s' "$response" | tail -n1)"
    health_body="$(printf '%s' "$response" | sed '$d')"
    if [[ "$http_code" == "200" ]] && jq -e '.status == "ok"' >/dev/null 2>&1 <<<"$health_body"; then
        break
    fi
    sleep 0.5
done

[[ "$http_code" == "200" ]] || {
    cat /tmp/kerno-health-curl.err >&2 || true
    fail "expected HTTP 200 from ${HEALTH_URL}, got ${http_code:-no response}"
}

jq -e '.status == "ok" and (.programsLoaded | type == "number") and (.programsTotal | type == "number")' \
    >/dev/null <<<"$health_body" || fail "unexpected health body: $health_body"
log "health endpoint returned: $health_body"

log "checking journal for startup failures"
journal="$(sudo journalctl -u "$SERVICE_NAME" --no-pager -n "$JOURNAL_LINES" || true)"
printf '%s\n' "$journal"
if grep -Eiq 'panic|fatal|address already in use|failed to start|start request repeated too quickly' <<<"$journal"; then
    fail "journal contains startup failure indicators"
fi

log "stopping ${SERVICE_NAME}"
sudo systemctl stop "$SERVICE_NAME"

inactive=""
for _ in {1..20}; do
    inactive="$(systemctl is-active "$SERVICE_NAME" || true)"
    if [[ "$inactive" == "inactive" ]]; then
        break
    fi
    sleep 0.5
done
[[ "$inactive" == "inactive" ]] || fail "expected ${SERVICE_NAME} to be inactive after stop, got ${inactive:-unknown}"

log "systemd runtime validation passed"
