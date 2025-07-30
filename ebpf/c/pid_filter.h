#ifndef __PID_FILTER_H__
#define __PID_FILTER_H__

// Special key to indicate if filtering is enabled
#define FILTER_ENABLED_KEY 0xFFFFFFFFFFFFFFFF

// Shared cgroup filter map across all eBPF programs
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 256);
    __type(key, __u64);   // cgroup ID (or FILTER_ENABLED_KEY for filter mode flag)
    __type(value, __u8);  // 1 = tracked or filter enabled
} cgroup_filter_map SEC(".maps");

// Helper function to check if current task should be tracked based on cgroup
static __always_inline int should_track_task() {
    __u64 filter_key = FILTER_ENABLED_KEY;
    __u8 *filter_enabled = bpf_map_lookup_elem(&cgroup_filter_map, &filter_key);
    
    // If filter is not enabled, track all tasks
    if (!filter_enabled || *filter_enabled == 0) {
        return 1;  // Track all tasks
    }
    
    // Get current task's cgroup ID
    __u64 cgroup_id = bpf_get_current_cgroup_id();
    
    // Check if this cgroup is being tracked
    __u8 *tracked = bpf_map_lookup_elem(&cgroup_filter_map, &cgroup_id);
    return (tracked && *tracked == 1);
}

#endif /* __PID_FILTER_H__ */

