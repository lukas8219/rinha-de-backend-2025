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
} tcp_connect_count SEC(".maps");

SEC("kprobe/tcp_v4_connect")
int kprobe__tcp_v4_connect(struct pt_regs *ctx)
{
    // Apply cgroup filter if configured
    if (!should_track_task()) {
        return 0;
    }
    
    __u32 pid = bpf_get_current_pid_tgid() >> 32;
    __u64 *count, one = 1;
    
    count = bpf_map_lookup_elem(&tcp_connect_count, &pid);
    if (count) {
        __sync_fetch_and_add(count, 1);
    } else {
        bpf_map_update_elem(&tcp_connect_count, &pid, &one, BPF_ANY);
    }
    
    return 0;
}

