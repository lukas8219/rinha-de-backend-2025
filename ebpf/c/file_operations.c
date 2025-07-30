//go:build ignore

#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>
#include "pid_filter.h"

char __license[] SEC("license") = "Dual MIT/GPL";

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 1024);
    __type(key, __u32);
    __type(value, __u64);
} file_open_count SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 1024);
    __type(key, __u32);
    __type(value, __u64);
} file_read_bytes SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 1024);
    __type(key, __u32);
    __type(value, __u64);
} file_write_bytes SEC(".maps");

SEC("tracepoint/syscalls/sys_enter_openat")
int tracepoint__syscalls__sys_enter_openat(void *ctx)
{
    // Apply cgroup filter if configured
    if (!should_track_task()) {
        return 0;
    }
    
    __u32 pid = bpf_get_current_pid_tgid() >> 32;
    __u64 *count, one = 1;
    
    count = bpf_map_lookup_elem(&file_open_count, &pid);
    if (count) {
        __sync_fetch_and_add(count, 1);
    } else {
        bpf_map_update_elem(&file_open_count, &pid, &one, BPF_ANY);
    }
    
    return 0;
}

SEC("tracepoint/syscalls/sys_exit_read")
int tracepoint__syscalls__sys_exit_read(struct trace_event_raw_sys_exit *ctx)
{
    // Apply cgroup filter if configured
    if (!should_track_task()) {
        return 0;
    }
    
    __u32 pid = bpf_get_current_pid_tgid() >> 32;
    long bytes = ctx->ret;
    
    if (bytes > 0) {
        __u64 *total, new_total = bytes;
        
        total = bpf_map_lookup_elem(&file_read_bytes, &pid);
        if (total) {
            new_total += *total;
            bpf_map_update_elem(&file_read_bytes, &pid, &new_total, BPF_ANY);
        } else {
            bpf_map_update_elem(&file_read_bytes, &pid, &new_total, BPF_ANY);
        }
    }
    
    return 0;
}

SEC("tracepoint/syscalls/sys_exit_write")
int tracepoint__syscalls__sys_exit_write(struct trace_event_raw_sys_exit *ctx)
{
    // Apply cgroup filter if configured
    if (!should_track_task()) {
        return 0;
    }
    
    __u32 pid = bpf_get_current_pid_tgid() >> 32;
    long bytes = ctx->ret;
    
    if (bytes > 0) {
        __u64 *total, new_total = bytes;
        
        total = bpf_map_lookup_elem(&file_write_bytes, &pid);
        if (total) {
            new_total += *total;
            bpf_map_update_elem(&file_write_bytes, &pid, &new_total, BPF_ANY);
        } else {
            bpf_map_update_elem(&file_write_bytes, &pid, &new_total, BPF_ANY);
        }
    }
    
    return 0;
}