// Copyright 2026 Lowplane contributors
// SPDX-License-Identifier: Apache-2.0

package metrics

import (
	"context"
	"fmt"
	"log/slog"
	"sync"

	"github.com/lowplane/kerno/internal/bpf"
)

// LabelCardinalityLimit caps the number of unique label combinations
// per metric to prevent unbounded memory growth from high-cardinality
// labels (e.g., per-PID processes).
const LabelCardinalityLimit = 5000

// Bridge reads raw eBPF events and feeds them into Prometheus metrics.
// Each loaded BPF program gets a goroutine that decodes events and
// updates the corresponding metric.
type Bridge struct {
	logger *slog.Logger

	mu       sync.Mutex
	seen     map[string]int // metric name → cardinality count
	cancelFn context.CancelFunc
}

// NewBridge creates a metrics bridge.
func NewBridge(logger *slog.Logger) *Bridge {
	return &Bridge{
		logger: logger,
		seen:   make(map[string]int),
	}
}

// Start launches a goroutine per loader that reads events and records metrics.
// It blocks until all goroutines are started, then returns. Call Stop() or
// cancel the parent context to shut them down.
func (b *Bridge) Start(ctx context.Context, loaders []bpf.Loader) {
	ctx, cancel := context.WithCancel(ctx)
	b.cancelFn = cancel

	for _, l := range loaders {
		ch, err := l.Events(ctx)
		if err != nil {
			b.logger.Debug("skipping metrics bridge for unloaded program",
				"program", l.Name())
			continue
		}
		go b.consume(ctx, l.Name(), ch)
		b.logger.Info("metrics bridge started", "program", l.Name())
	}
}

// Stop cancels the bridge context, causing all consume goroutines to exit.
func (b *Bridge) Stop() {
	if b.cancelFn != nil {
		b.cancelFn()
	}
}

// cardinalityOK returns true if the metric has not exceeded the label
// cardinality limit. This is a simple counter — not a true cardinality
// tracker (would need an LRU or HyperLogLog for production), but
// sufficient as a safety valve.
func (b *Bridge) cardinalityOK(metric string) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.seen[metric]++
	return b.seen[metric] <= LabelCardinalityLimit
}

func (b *Bridge) consume(ctx context.Context, name string, ch <-chan bpf.RawEvent) {
	for {
		select {
		case <-ctx.Done():
			return
		case raw, ok := <-ch:
			if !ok {
				return
			}
			CollectorEventsTotal.WithLabelValues(name).Inc()
			b.record(name, raw)
		}
	}
}

func (b *Bridge) record(name string, raw bpf.RawEvent) {
	switch name {
	case "syscall_latency":
		b.recordSyscall(raw)
	case "tcp_monitor":
		b.recordTCP(raw)
	case "oom_track":
		b.recordOOM(raw)
	case "disk_io":
		b.recordDiskIO(raw)
	case "sched_delay":
		b.recordSchedDelay(raw)
	case "fd_track":
		b.recordFD(raw)
	default:
		// Unknown program — count it but don't decode.
	}
}

func (b *Bridge) recordSyscall(raw bpf.RawEvent) {
	event, err := bpf.DecodeSyscallEvent(raw.Data)
	if err != nil {
		CollectorErrorsTotal.WithLabelValues("syscall_latency").Inc()
		return
	}
	if !b.cardinalityOK("syscall") {
		return
	}
	comm := event.CommString()
	sc := syscallName(event.SyscallNr)
	SyscallDuration.WithLabelValues(sc, comm).Observe(float64(event.LatencyNs))
	SyscallTotal.WithLabelValues(sc, comm).Inc()
}

func (b *Bridge) recordTCP(raw bpf.RawEvent) {
	event, err := bpf.DecodeTCPEvent(raw.Data)
	if err != nil {
		CollectorErrorsTotal.WithLabelValues("tcp_monitor").Inc()
		return
	}
	if !b.cardinalityOK("tcp") {
		return
	}
	src := event.SrcAddr().String()
	dst := event.DstAddr().String()
	comm := event.CommString()

	TCPConnectionsTotal.WithLabelValues(src, dst, comm).Inc()

	if event.RTTUs > 0 {
		TCPRTT.WithLabelValues(src, dst, comm).Observe(float64(event.RTTUs) * 1000) // us → ns
	}
	if event.Retransmits > 0 {
		TCPRetransmitsTotal.WithLabelValues(src, dst, comm).Add(float64(event.Retransmits))
	}
}

func (b *Bridge) recordOOM(raw bpf.RawEvent) {
	event, err := bpf.DecodeOOMEvent(raw.Data)
	if err != nil {
		CollectorErrorsTotal.WithLabelValues("oom_track").Inc()
		return
	}
	comm := event.CommString()
	OOMKillsTotal.WithLabelValues(comm).Inc()
}

func (b *Bridge) recordDiskIO(raw bpf.RawEvent) {
	event, err := bpf.DecodeDiskEvent(raw.Data)
	if err != nil {
		CollectorErrorsTotal.WithLabelValues("disk_io").Inc()
		return
	}
	if !b.cardinalityOK("disk_io") {
		return
	}
	dev := formatDev(event.Dev)
	op := event.OpString()
	DiskIODuration.WithLabelValues(dev, op).Observe(float64(event.LatencyNs))
	DiskIOBytesTotal.WithLabelValues(dev, op).Add(float64(event.NrBytes))
}

func (b *Bridge) recordSchedDelay(raw bpf.RawEvent) {
	event, err := bpf.DecodeSchedEvent(raw.Data)
	if err != nil {
		CollectorErrorsTotal.WithLabelValues("sched_delay").Inc()
		return
	}
	if !b.cardinalityOK("sched_delay") {
		return
	}
	comm := event.CommString()
	SchedDelay.WithLabelValues(comm).Observe(float64(event.RunqDelayNs))
}

func (b *Bridge) recordFD(raw bpf.RawEvent) {
	event, err := bpf.DecodeFDEvent(raw.Data)
	if err != nil {
		CollectorErrorsTotal.WithLabelValues("fd_track").Inc()
		return
	}
	if !b.cardinalityOK("fd_track") {
		return
	}
	comm := event.CommString()
	switch event.Op {
	case bpf.FDOpOpen:
		FDOpenTotal.WithLabelValues(comm).Inc()
	case bpf.FDOpClose:
		FDCloseTotal.WithLabelValues(comm).Inc()
	}
}

// formatDev formats a kernel dev_t (major<<20 | minor) into "major:minor".
func formatDev(dev uint32) string {
	major := dev >> 20
	minor := dev & ((1 << 20) - 1)
	return fmt.Sprintf("%d:%d", major, minor)
}

// syscallName returns the name for a Linux syscall number on amd64.
// Covers the most common syscalls; unknown numbers return "syscall_NR".
func syscallName(nr uint32) string {
	names := map[uint32]string{
		0: "read", 1: "write", 2: "open", 3: "close",
		4: "stat", 5: "fstat", 6: "lstat", 7: "poll",
		8: "lseek", 9: "mmap", 10: "mprotect", 11: "munmap",
		12: "brk", 13: "rt_sigaction", 14: "rt_sigprocmask",
		16: "ioctl", 17: "pread64", 18: "pwrite64",
		19: "readv", 20: "writev", 21: "access",
		22: "pipe", 23: "select", 24: "sched_yield",
		32: "dup", 33: "dup2",
		39: "getpid", 41: "socket", 42: "connect", 43: "accept",
		44: "sendto", 45: "recvfrom", 46: "sendmsg", 47: "recvmsg",
		48: "shutdown", 49: "bind", 50: "listen",
		56: "clone", 57: "fork", 58: "vfork", 59: "execve",
		60: "exit", 61: "wait4", 62: "kill",
		72: "fcntl", 73: "flock", 74: "fsync", 75: "fdatasync",
		77: "ftruncate", 78: "getdents",
		79: "getcwd", 80: "chdir", 82: "rename",
		83: "mkdir", 84: "rmdir", 85: "creat", 86: "link", 87: "unlink",
		89: "readlink", 90: "chmod", 92: "chown",
		137: "statfs", 186: "gettid",
		202: "futex", 217: "getdents64",
		231: "exit_group", 232: "epoll_wait",
		257: "openat", 262: "newfstatat",
		268: "fchmodat", 280: "utimensat",
		288: "accept4", 290: "sendmmsg",
		302: "prlimit64", 318: "getrandom",
		332: "statx",
		435: "clone3",
	}
	if name, ok := names[nr]; ok {
		return name
	}
	return fmt.Sprintf("syscall_%d", nr)
}
