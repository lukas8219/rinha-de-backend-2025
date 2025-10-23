//go:build ignore

#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>
#include "pid_filter.h"

char __license[] SEC("license") = "Dual MIT/GPL";

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 10240);
    __type(key, __u32);
    __type(value, __u64);
} tx_bytes SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 10240);
    __type(key, __u32);
    __type(value, __u64);
} rx_bytes SEC(".maps");

SEC("kprobe/tcp_sendmsg")
int kprobe__tcp_sendmsg(struct pt_regs *ctx)
{
    // Apply cgroup filter if configured
    if (!should_track_task()) {
        return 0;
    }
    
    __u32 pid = bpf_get_current_pid_tgid() >> 32;
    size_t size = PT_REGS_PARM3(ctx);
    __u64 *total, new_total = size;
    
    total = bpf_map_lookup_elem(&tx_bytes, &pid);
    if (total) {
        new_total += *total;
        bpf_map_update_elem(&tx_bytes, &pid, &new_total, BPF_ANY);
    } else {
        bpf_map_update_elem(&tx_bytes, &pid, &new_total, BPF_ANY);
    }
    
    return 0;
}

SEC("kprobe/tcp_recvmsg")
int kprobe__tcp_recvmsg(struct pt_regs *ctx)
{
    // Apply cgroup filter if configured
    if (!should_track_task()) {
        return 0;
    }
    
    __u32 pid = bpf_get_current_pid_tgid() >> 32;
    __u64 one = 1;
    
    bpf_map_update_elem(&rx_bytes, &pid, &one, BPF_ANY);
    
    return 0;
}

SEC("kretprobe/tcp_recvmsg")
int kretprobe__tcp_recvmsg(struct pt_regs *ctx)
{
    // Apply cgroup filter if configured
    if (!should_track_task()) {
        return 0;
    }
    
    __u32 pid = bpf_get_current_pid_tgid() >> 32;
    int bytes_read = PT_REGS_RC(ctx);
    
    if (bytes_read > 0) {
        __u64 *total, new_total = bytes_read;
        
        total = bpf_map_lookup_elem(&rx_bytes, &pid);
        if (total) {
            new_total += *total;
            bpf_map_update_elem(&rx_bytes, &pid, &new_total, BPF_ANY);
        } else {
            bpf_map_update_elem(&rx_bytes, &pid, &new_total, BPF_ANY);
        }
    }
    
    return 0;
}

