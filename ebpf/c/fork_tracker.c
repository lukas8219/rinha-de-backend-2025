//go:build ignore

#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>
#include "pid_filter.h"

char __license[] SEC("license") = "Dual MIT/GPL";

// With cgroup-based filtering, forks inherit the parent's cgroup automatically
// So we don't need to do anything special - just keep the map definition
// for pinning/sharing purposes

// Minimal tracking to ensure cgroup is in the map if a new one is seen
SEC("tracepoint/syscalls/sys_exit_clone")
int tracepoint__syscalls__sys_exit_clone(struct trace_event_raw_sys_exit *ctx)
{
    // With cgroup filtering, child processes automatically inherit parent's cgroup
    // No action needed - cgroup ID remains the same
    return 0;
}

SEC("tracepoint/syscalls/sys_exit_fork")
int tracepoint__syscalls__sys_exit_fork(struct trace_event_raw_sys_exit *ctx)
{
    // With cgroup filtering, child processes automatically inherit parent's cgroup
    // No action needed - cgroup ID remains the same
    return 0;
}

SEC("tracepoint/syscalls/sys_exit_vfork")
int tracepoint__syscalls__sys_exit_vfork(struct trace_event_raw_sys_exit *ctx)
{
    // With cgroup filtering, child processes automatically inherit parent's cgroup
    // No action needed - cgroup ID remains the same
    return 0;
}

