package main

import (
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/cilium/ebpf"
	"github.com/cilium/ebpf/link"
	"github.com/cilium/ebpf/rlimit"
)

func main() {
	// Parse command line flags
	pidsFlag := flag.String("pids", "", "Comma-separated list of PIDs to filter (e.g., 1234,5678). If not specified, all PIDs are tracked.")
	flag.Parse()

	if err := rlimit.RemoveMemlock(); err != nil {
		log.Fatal(err)
	}

	// Parse PIDs to filter
	var filterCgroups []uint64
	if *pidsFlag != "" {
		pidStrs := strings.Split(*pidsFlag, ",")
		var pids []uint32
		for _, pidStr := range pidStrs {
			pidStr = strings.TrimSpace(pidStr)
			pid, err := strconv.ParseUint(pidStr, 10, 32)
			if err != nil {
				log.Fatalf("Invalid PID: %s", pidStr)
			}
			pids = append(pids, uint32(pid))
		}
		
		// Get cgroup IDs from the specified PIDs
		cgroupSet := make(map[uint64]bool)
		for _, pid := range pids {
			cgid, err := getCgroupID(pid)
			if err != nil {
				log.Printf("Warning: Failed to get cgroup for PID %d: %v", pid, err)
				continue
			}
			cgroupSet[cgid] = true
		}
		
		for cgid := range cgroupSet {
			filterCgroups = append(filterCgroups, cgid)
		}
		
		fmt.Printf("🔍 Filtering for PIDs: %v\n", pids)
		fmt.Printf("📊 Found %d unique cgroup(s)\n", len(filterCgroups))
	} else {
		fmt.Println("🔍 Tracking all PIDs (no filter applied)")
	}

	// Pin path for shared cgroup filter map
	pinDir := "/sys/fs/bpf"
	pinPath := filepath.Join(pinDir, "cgroup_filter_map")
	
	// Remove any existing pinned map
	os.Remove(pinPath)
	
	// Load fork tracker first (for map sharing) with pinning enabled
	forkTracker, err := loadForkTrackerWithPin(pinDir)
	if err != nil {
		log.Printf("Warning: Failed to load fork_tracker: %v", err)
	} else {
		defer forkTracker.Close()
		defer os.Remove(pinPath) // Clean up on exit
		fmt.Println("✓ Loaded cgroup filter map")
		
		// Initialize cgroup filter map if PIDs specified
		if len(filterCgroups) > 0 {
			if err := initCgroupFilter(forkTracker.objs, filterCgroups); err != nil {
				log.Fatalf("Failed to initialize cgroup filter: %v", err)
			}
			// Debug: verify the filter map contents
			debugCgroupFilterMap(forkTracker.objs)
		}
	}

	// Load and attach all eBPF programs with shared PID filter map
	tcpConnect, err := loadTCPConnectWithPinnedMap(pinPath)
	if err != nil {
		log.Printf("Warning: Failed to load tcp_connect: %v", err)
	} else {
		defer tcpConnect.Close()
		fmt.Println("✓ Loaded tcp_connect.o")
	}

	networkTraffic, err := loadNetworkTrafficWithPinnedMap(pinPath)
	if err != nil {
		log.Printf("Warning: Failed to load network_traffic: %v", err)
	} else {
		defer networkTraffic.Close()
		fmt.Println("✓ Loaded network_traffic.o")
	}

	fileOps, err := loadFileOperationsWithPinnedMap(pinPath)
	if err != nil {
		log.Printf("Warning: Failed to load file_operations: %v", err)
	} else {
		defer fileOps.Close()
		fmt.Println("✓ Loaded file_operations.o")
	}

	fmt.Println("\n🔍 Monitoring system events... Press Ctrl+C to stop\n")

	// Setup signal handler
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)

	ticker := time.NewTicker(1 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-ticker.C:
			printStats(tcpConnect, networkTraffic, fileOps)
		case <-sig:
			fmt.Println("\n\nShutting down...")
			return
		}
	}
}

type TCPConnectProg struct {
	objs *ebpf.Collection
	link link.Link
}

func (t *TCPConnectProg) Close() {
	if t.link != nil {
		t.link.Close()
	}
	if t.objs != nil {
		t.objs.Close()
	}
}

func getObjectFilePath(name string) string {
	return filepath.Join("c", name + ".o")
}

func loadTCPConnect() (*TCPConnectProg, error) {
	spec, err := ebpf.LoadCollectionSpec(getObjectFilePath("tcp_connect"))
	if err != nil {
		return nil, fmt.Errorf("loading spec: %w", err)
	}

	objs, err := ebpf.NewCollection(spec)
	if err != nil {
		return nil, fmt.Errorf("loading objects: %w", err)
	}

	prog := objs.Programs["kprobe__tcp_v4_connect"]
	if prog == nil {
		objs.Close()
		return nil, fmt.Errorf("program kprobe__tcp_v4_connect not found")
	}

	kp, err := link.Kprobe("tcp_v4_connect", prog, nil)
	if err != nil {
		objs.Close()
		return nil, fmt.Errorf("attaching kprobe: %w", err)
	}

	return &TCPConnectProg{objs: objs, link: kp}, nil
}

func loadTCPConnectWithPinnedMap(pinPath string) (*TCPConnectProg, error) {
	spec, err := ebpf.LoadCollectionSpec(getObjectFilePath("tcp_connect"))
	if err != nil {
		return nil, fmt.Errorf("loading spec: %w", err)
	}

	// Load the pinned map
	pinnedMap, err := ebpf.LoadPinnedMap(pinPath, nil)
	if err != nil {
		// If pinned map doesn't exist, load without it
		return loadTCPConnect()
	}
	defer pinnedMap.Close() // Close this reference; the collection will keep its own

	// Tell the spec to reuse the existing pinned map
	opts := ebpf.CollectionOptions{
		Maps: ebpf.MapOptions{},
	}
	opts.Maps.PinPath = filepath.Dir(pinPath)

	// Set the map to be loaded from the pinned location
	if mapSpec, ok := spec.Maps["cgroup_filter_map"]; ok {
		mapSpec.Pinning = ebpf.PinByName
	}

	// Create collection - it will reuse the pinned map
	coll, err := ebpf.NewCollectionWithOptions(spec, opts)
	if err != nil {
		return nil, fmt.Errorf("loading objects: %w", err)
	}

	prog := coll.Programs["kprobe__tcp_v4_connect"]
	if prog == nil {
		coll.Close()
		return nil, fmt.Errorf("program kprobe__tcp_v4_connect not found")
	}

	kp, err := link.Kprobe("tcp_v4_connect", prog, nil)
	if err != nil {
		coll.Close()
		return nil, fmt.Errorf("attaching kprobe: %w", err)
	}

	return &TCPConnectProg{objs: coll, link: kp}, nil
}

type NetworkTrafficProg struct {
	objs   *ebpf.Collection
	links  []link.Link
}

func (n *NetworkTrafficProg) Close() {
	for _, l := range n.links {
		if l != nil {
			l.Close()
		}
	}
	if n.objs != nil {
		n.objs.Close()
	}
}

func loadNetworkTraffic() (*NetworkTrafficProg, error) {
	spec, err := ebpf.LoadCollectionSpec(getObjectFilePath("network_traffic"))
	if err != nil {
		return nil, fmt.Errorf("loading spec: %w", err)
	}

	objs, err := ebpf.NewCollection(spec)
	if err != nil {
		return nil, fmt.Errorf("loading objects: %w", err)
	}

	var links []link.Link

	// Attach tcp_sendmsg kprobe
	prog := objs.Programs["kprobe__tcp_sendmsg"]
	if prog != nil {
		kp, err := link.Kprobe("tcp_sendmsg", prog, nil)
		if err != nil {
			objs.Close()
			return nil, fmt.Errorf("attaching tcp_sendmsg kprobe: %w", err)
		}
		links = append(links, kp)
	}

	// Attach tcp_recvmsg kprobe
	prog = objs.Programs["kprobe__tcp_recvmsg"]
	if prog != nil {
		kp, err := link.Kprobe("tcp_recvmsg", prog, nil)
		if err != nil {
			objs.Close()
			return nil, fmt.Errorf("attaching tcp_recvmsg kprobe: %w", err)
		}
		links = append(links, kp)
	}

	// Attach tcp_recvmsg kretprobe
	prog = objs.Programs["kretprobe__tcp_recvmsg"]
	if prog != nil {
		kp, err := link.Kretprobe("tcp_recvmsg", prog, nil)
		if err != nil {
			objs.Close()
			return nil, fmt.Errorf("attaching tcp_recvmsg kretprobe: %w", err)
		}
		links = append(links, kp)
	}

	return &NetworkTrafficProg{objs: objs, links: links}, nil
}

func loadNetworkTrafficWithPinnedMap(pinPath string) (*NetworkTrafficProg, error) {
	spec, err := ebpf.LoadCollectionSpec(getObjectFilePath("network_traffic"))
	if err != nil {
		return nil, fmt.Errorf("loading spec: %w", err)
	}

	// Load the pinned map to verify it exists
	pinnedMap, err := ebpf.LoadPinnedMap(pinPath, nil)
	if err != nil {
		return loadNetworkTraffic()
	}
	defer pinnedMap.Close()

	// Tell the spec to reuse the existing pinned map
	opts := ebpf.CollectionOptions{
		Maps: ebpf.MapOptions{},
	}
	opts.Maps.PinPath = filepath.Dir(pinPath)

	// Set the map to be loaded from the pinned location
	if mapSpec, ok := spec.Maps["cgroup_filter_map"]; ok {
		mapSpec.Pinning = ebpf.PinByName
	}

	coll, err := ebpf.NewCollectionWithOptions(spec, opts)
	if err != nil {
		return nil, fmt.Errorf("loading objects: %w", err)
	}

	var links []link.Link

	// Attach tcp_sendmsg kprobe
	prog := coll.Programs["kprobe__tcp_sendmsg"]
	if prog != nil {
		kp, err := link.Kprobe("tcp_sendmsg", prog, nil)
		if err != nil {
			coll.Close()
			return nil, fmt.Errorf("attaching tcp_sendmsg kprobe: %w", err)
		}
		links = append(links, kp)
	}

	// Attach tcp_recvmsg kprobe
	prog = coll.Programs["kprobe__tcp_recvmsg"]
	if prog != nil {
		kp, err := link.Kprobe("tcp_recvmsg", prog, nil)
		if err != nil {
			coll.Close()
			return nil, fmt.Errorf("attaching tcp_recvmsg kprobe: %w", err)
		}
		links = append(links, kp)
	}

	// Attach tcp_recvmsg kretprobe
	prog = coll.Programs["kretprobe__tcp_recvmsg"]
	if prog != nil {
		kp, err := link.Kretprobe("tcp_recvmsg", prog, nil)
		if err != nil {
			coll.Close()
			return nil, fmt.Errorf("attaching tcp_recvmsg kretprobe: %w", err)
		}
		links = append(links, kp)
	}

	return &NetworkTrafficProg{objs: coll, links: links}, nil
}

type FileOperationsProg struct {
	objs   *ebpf.Collection
	links  []link.Link
}

func (f *FileOperationsProg) Close() {
	for _, l := range f.links {
		if l != nil {
			l.Close()
		}
	}
	if f.objs != nil {
		f.objs.Close()
	}
}

func loadFileOperations() (*FileOperationsProg, error) {
	spec, err := ebpf.LoadCollectionSpec(getObjectFilePath("file_operations"))
	if err != nil {
		return nil, fmt.Errorf("loading spec: %w", err)
	}

	objs, err := ebpf.NewCollection(spec)
	if err != nil {
		return nil, fmt.Errorf("loading objects: %w", err)
	}

	var links []link.Link

	// Attach sys_enter_openat tracepoint
	prog := objs.Programs["tracepoint__syscalls__sys_enter_openat"]
	if prog != nil {
		tp, err := link.Tracepoint("syscalls", "sys_enter_openat", prog, nil)
		if err != nil {
			objs.Close()
			return nil, fmt.Errorf("attaching sys_enter_openat: %w", err)
		}
		links = append(links, tp)
	}

	// Attach sys_exit_read tracepoint
	prog = objs.Programs["tracepoint__syscalls__sys_exit_read"]
	if prog != nil {
		tp, err := link.Tracepoint("syscalls", "sys_exit_read", prog, nil)
		if err != nil {
			objs.Close()
			return nil, fmt.Errorf("attaching sys_exit_read: %w", err)
		}
		links = append(links, tp)
	}

	// Attach sys_exit_write tracepoint
	prog = objs.Programs["tracepoint__syscalls__sys_exit_write"]
	if prog != nil {
		tp, err := link.Tracepoint("syscalls", "sys_exit_write", prog, nil)
		if err != nil {
			objs.Close()
			return nil, fmt.Errorf("attaching sys_exit_write: %w", err)
		}
		links = append(links, tp)
	}

	return &FileOperationsProg{objs: objs, links: links}, nil
}

func loadFileOperationsWithPinnedMap(pinPath string) (*FileOperationsProg, error) {
	spec, err := ebpf.LoadCollectionSpec(getObjectFilePath("file_operations"))
	if err != nil {
		return nil, fmt.Errorf("loading spec: %w", err)
	}

	// Load the pinned map to verify it exists
	pinnedMap, err := ebpf.LoadPinnedMap(pinPath, nil)
	if err != nil {
		return loadFileOperations()
	}
	defer pinnedMap.Close()

	// Tell the spec to reuse the existing pinned map
	opts := ebpf.CollectionOptions{
		Maps: ebpf.MapOptions{},
	}
	opts.Maps.PinPath = filepath.Dir(pinPath)

	// Set the map to be loaded from the pinned location
	if mapSpec, ok := spec.Maps["cgroup_filter_map"]; ok {
		mapSpec.Pinning = ebpf.PinByName
	}

	coll, err := ebpf.NewCollectionWithOptions(spec, opts)
	if err != nil {
		return nil, fmt.Errorf("loading objects: %w", err)
	}

	var links []link.Link

	// Attach sys_enter_openat tracepoint
	prog := coll.Programs["tracepoint__syscalls__sys_enter_openat"]
	if prog != nil {
		tp, err := link.Tracepoint("syscalls", "sys_enter_openat", prog, nil)
		if err != nil {
			coll.Close()
			return nil, fmt.Errorf("attaching sys_enter_openat: %w", err)
		}
		links = append(links, tp)
	}

	// Attach sys_exit_read tracepoint
	prog = coll.Programs["tracepoint__syscalls__sys_exit_read"]
	if prog != nil {
		tp, err := link.Tracepoint("syscalls", "sys_exit_read", prog, nil)
		if err != nil {
			coll.Close()
			return nil, fmt.Errorf("attaching sys_exit_read: %w", err)
		}
		links = append(links, tp)
	}

	// Attach sys_exit_write tracepoint
	prog = coll.Programs["tracepoint__syscalls__sys_exit_write"]
	if prog != nil {
		tp, err := link.Tracepoint("syscalls", "sys_exit_write", prog, nil)
		if err != nil {
			coll.Close()
			return nil, fmt.Errorf("attaching sys_exit_write: %w", err)
		}
		links = append(links, tp)
	}

	return &FileOperationsProg{objs: coll, links: links}, nil
}

func printStats(tcpConnect *TCPConnectProg, networkTraffic *NetworkTrafficProg,
	fileOps *FileOperationsProg) {

	fmt.Println("════════════════════════════════════════════════════════════")
	fmt.Printf("📊 Statistics at %s\n", time.Now().Format("15:04:05"))
	fmt.Println("════════════════════════════════════════════════════════════")

	// TCP Connect Stats
	if tcpConnect != nil && tcpConnect.objs != nil {
		m := tcpConnect.objs.Maps["tcp_connect_count"]
		if m != nil {
			fmt.Println("\n🌐 TCP Connections by PID:")
			printMap(m, "  PID %d: %d connections")
		}
	}

	// Network Traffic Stats
	if networkTraffic != nil && networkTraffic.objs != nil {
		txMap := networkTraffic.objs.Maps["tx_bytes"]
		rxMap := networkTraffic.objs.Maps["rx_bytes"]
		
		if txMap != nil {
			fmt.Println("\n📤 TX Traffic by PID:")
			printMap(txMap, "  PID %d: %d bytes sent")
		}
		
		if rxMap != nil {
			fmt.Println("\n📥 RX Traffic by PID:")
			printMap(rxMap, "  PID %d: %d bytes received")
		}
	}

	// Process Exec Stats

	// File Operations Stats
	if fileOps != nil && fileOps.objs != nil {
		openMap := fileOps.objs.Maps["file_open_count"]
		readMap := fileOps.objs.Maps["file_read_bytes"]
		writeMap := fileOps.objs.Maps["file_write_bytes"]
		
		if openMap != nil {
			fmt.Println("\n📂 File Opens by PID:")
			printMap(openMap, "  PID %d: %d opens")
		}
		
		if readMap != nil {
			fmt.Println("\n📖 File Reads by PID:")
			printMap(readMap, "  PID %d: %d bytes read")
		}
		
		if writeMap != nil {
			fmt.Println("\n📝 File Writes by PID:")
			printMap(writeMap, "  PID %d: %d bytes written")
		}
	}

	fmt.Println("\n════════════════════════════════════════════════════════════\n")
}

func printMap(m *ebpf.Map, format string) {
	var (
		key   uint32
		value uint64
	)

	iter := m.Iterate()
	count := 0
	for iter.Next(&key, &value) && count < 10 {
		cmdName := getProcessName(key)
		if cmdName != "" {
			fmt.Printf(format+" (%s)\n", key, value, cmdName)
		} else {
			fmt.Printf(format+"\n", key, value)
		}
		count++
	}
	if count == 0 {
		fmt.Println("  (no data yet)")
	}
}

func getProcessName(pid uint32) string {
	// Try to read /proc/[pid]/comm for process name
	commPath := fmt.Sprintf("/proc/%d/comm", pid)
	data, err := os.ReadFile(commPath)
	if err != nil {
		// Process might have exited, return empty string
		return ""
	}
	// Remove trailing newline
	name := strings.TrimSpace(string(data))
	return name
}

func printSyscallMap(m *ebpf.Map) {
	var (
		key   uint64
		value uint64
	)

	type syscallStat struct {
		id    uint64
		count uint64
	}

	var stats []syscallStat
	iter := m.Iterate()
	for iter.Next(&key, &value) {
		stats = append(stats, syscallStat{id: key, count: value})
	}

	// Sort by count (simple bubble sort for top 10)
	for i := 0; i < len(stats) && i < 10; i++ {
		for j := i + 1; j < len(stats); j++ {
			if stats[j].count > stats[i].count {
				stats[i], stats[j] = stats[j], stats[i]
			}
		}
	}

	if len(stats) == 0 {
		fmt.Println("  (no data yet)")
		return
	}

	for i := 0; i < len(stats) && i < 10; i++ {
		syscallName := getSyscallName(stats[i].id)
		fmt.Printf("  Syscall %s (%d): %d calls\n", syscallName, stats[i].id, stats[i].count)
	}
}

func getSyscallName(id uint64) string {
	// Common syscall numbers for x86_64
	syscallNames := map[uint64]string{
		0: "read", 1: "write", 2: "open", 3: "close", 4: "stat",
		5: "fstat", 6: "lstat", 7: "poll", 8: "lseek", 9: "mmap",
		10: "mprotect", 11: "munmap", 12: "brk", 13: "rt_sigaction",
		14: "rt_sigprocmask", 15: "rt_sigreturn", 16: "ioctl",
		17: "pread64", 18: "pwrite64", 19: "readv", 20: "writev",
		21: "access", 22: "pipe", 23: "select", 24: "sched_yield",
		25: "mremap", 26: "msync", 27: "mincore", 28: "madvise",
		39: "getpid", 56: "clone", 57: "fork", 59: "execve",
		60: "exit", 61: "wait4", 62: "kill", 63: "uname",
		72: "fcntl", 73: "flock", 74: "fsync", 78: "getdents",
		79: "getcwd", 80: "chdir", 81: "fchdir", 82: "rename",
		83: "mkdir", 84: "rmdir", 85: "creat", 86: "link",
		87: "unlink", 88: "symlink", 89: "readlink", 90: "chmod",
		217: "getdents64", 257: "openat", 258: "mkdirat",
		262: "newfstatat", 263: "unlinkat",
	}

	if name, ok := syscallNames[id]; ok {
		return name
	}
	return "unknown"
}

type ForkTrackerProg struct {
	objs   *ebpf.Collection
	links  []link.Link
}

func (f *ForkTrackerProg) Close() {
	for _, l := range f.links {
		if l != nil {
			l.Close()
		}
	}
	if f.objs != nil {
		f.objs.Close()
	}
}

func loadForkTracker() (*ForkTrackerProg, error) {
	spec, err := ebpf.LoadCollectionSpec(getObjectFilePath("fork_tracker"))
	if err != nil {
		return nil, fmt.Errorf("loading spec: %w", err)
	}

	objs, err := ebpf.NewCollection(spec)
	if err != nil {
		return nil, fmt.Errorf("loading objects: %w", err)
	}

	var links []link.Link

	// Attach sys_exit_clone tracepoint
	prog := objs.Programs["tracepoint__syscalls__sys_exit_clone"]
	if prog != nil {
		tp, err := link.Tracepoint("syscalls", "sys_exit_clone", prog, nil)
		if err != nil {
			log.Printf("Warning: Failed to attach sys_exit_clone: %v", err)
		} else {
			links = append(links, tp)
		}
	}

	// Attach sys_exit_fork tracepoint
	prog = objs.Programs["tracepoint__syscalls__sys_exit_fork"]
	if prog != nil {
		tp, err := link.Tracepoint("syscalls", "sys_exit_fork", prog, nil)
		if err != nil {
			log.Printf("Warning: Failed to attach sys_exit_fork: %v", err)
		} else {
			links = append(links, tp)
		}
	}

	// Attach sys_exit_vfork tracepoint
	prog = objs.Programs["tracepoint__syscalls__sys_exit_vfork"]
	if prog != nil {
		tp, err := link.Tracepoint("syscalls", "sys_exit_vfork", prog, nil)
		if err != nil {
			log.Printf("Warning: Failed to attach sys_exit_vfork: %v", err)
		} else {
			links = append(links, tp)
		}
	}

	return &ForkTrackerProg{objs: objs, links: links}, nil
}

func loadForkTrackerWithPin(pinDir string) (*ForkTrackerProg, error) {
	spec, err := ebpf.LoadCollectionSpec(getObjectFilePath("fork_tracker"))
	if err != nil {
		return nil, fmt.Errorf("loading spec: %w", err)
	}

	// Enable pinning for the cgroup_filter_map
	if mapSpec, ok := spec.Maps["cgroup_filter_map"]; ok {
		mapSpec.Pinning = ebpf.PinByName
	}

	// Set pin path in options
	opts := ebpf.CollectionOptions{
		Maps: ebpf.MapOptions{
			PinPath: pinDir,
		},
	}

	objs, err := ebpf.NewCollectionWithOptions(spec, opts)
	if err != nil {
		return nil, fmt.Errorf("loading objects: %w", err)
	}

	var links []link.Link

	// Attach sys_exit_clone tracepoint
	prog := objs.Programs["tracepoint__syscalls__sys_exit_clone"]
	if prog != nil {
		tp, err := link.Tracepoint("syscalls", "sys_exit_clone", prog, nil)
		if err != nil {
			log.Printf("Warning: Failed to attach sys_exit_clone: %v", err)
		} else {
			links = append(links, tp)
		}
	}

	// Attach sys_exit_fork tracepoint
	prog = objs.Programs["tracepoint__syscalls__sys_exit_fork"]
	if prog != nil {
		tp, err := link.Tracepoint("syscalls", "sys_exit_fork", prog, nil)
		if err != nil {
			log.Printf("Warning: Failed to attach sys_exit_fork: %v", err)
		} else {
			links = append(links, tp)
		}
	}

	// Attach sys_exit_vfork tracepoint
	prog = objs.Programs["tracepoint__syscalls__sys_exit_vfork"]
	if prog != nil {
		tp, err := link.Tracepoint("syscalls", "sys_exit_vfork", prog, nil)
		if err != nil {
			log.Printf("Warning: Failed to attach sys_exit_vfork: %v", err)
		} else {
			links = append(links, tp)
		}
	}

	return &ForkTrackerProg{objs: objs, links: links}, nil
}

func initCgroupFilter(objs *ebpf.Collection, cgroupIDs []uint64) error {
	cgroupFilterMap := objs.Maps["cgroup_filter_map"]
	if cgroupFilterMap == nil {
		return fmt.Errorf("cgroup_filter_map not found")
	}

	// Set the filter enabled flag (key 0xFFFFFFFFFFFFFFFF)
	filterEnabledKey := uint64(0xFFFFFFFFFFFFFFFF)
	filterEnabled := uint8(1)
	if err := cgroupFilterMap.Put(filterEnabledKey, filterEnabled); err != nil {
		return fmt.Errorf("failed to enable cgroup filter: %w", err)
	}

	// Add each cgroup ID to the filter map
	tracked := uint8(1)
	for _, cgid := range cgroupIDs {
		if err := cgroupFilterMap.Put(cgid, tracked); err != nil {
			return fmt.Errorf("failed to add cgroup ID %d to filter: %w", cgid, err)
		}
	}

	fmt.Printf("✓ Initialized cgroup filter with %d cgroup(s)\n", len(cgroupIDs))
	return nil
}

func debugCgroupFilterMap(objs *ebpf.Collection) {
	cgroupFilterMap := objs.Maps["cgroup_filter_map"]
	if cgroupFilterMap == nil {
		return
	}

	fmt.Printf("📋 Cgroup Filter Map Contents:\n")
	
	var (
		key   uint64
		value uint8
	)
	
	iter := cgroupFilterMap.Iterate()
	count := 0
	for iter.Next(&key, &value) {
		if key == 0xFFFFFFFFFFFFFFFF {
			fmt.Printf("  Filter Enabled: %v\n", value == 1)
		} else {
			fmt.Printf("  Cgroup ID %d: tracked=%v\n", key, value == 1)
		}
		count++
	}
	
	if count == 0 {
		fmt.Println("  (empty map - this is a problem!)")
	}
	fmt.Println()
}

// getCgroupID returns the cgroup ID for a given PID
func getCgroupID(pid uint32) (uint64, error) {
	// Read cgroup info from /proc/[pid]/cgroup
	cgroupPath := fmt.Sprintf("/proc/%d/cgroup", pid)
	data, err := os.ReadFile(cgroupPath)
	if err != nil {
		return 0, fmt.Errorf("failed to read cgroup file: %w", err)
	}
	
	// Parse cgroup file to find the unified cgroup path (cgroup v2)
	// Format: 0::/path/to/cgroup
	lines := strings.Split(string(data), "\n")
	var cgroupPathStr string
	for _, line := range lines {
		if strings.HasPrefix(line, "0::") {
			cgroupPathStr = strings.TrimPrefix(line, "0::")
			break
		}
	}
	
	if cgroupPathStr == "" {
		// Fallback: try to find any cgroup line
		for _, line := range lines {
			parts := strings.SplitN(line, ":", 3)
			if len(parts) == 3 {
				cgroupPathStr = parts[2]
				break
			}
		}
	}
	
	if cgroupPathStr == "" {
		return 0, fmt.Errorf("could not parse cgroup path")
	}
	
	// Get the cgroup inode (which is the cgroup ID)
	// The cgroup filesystem is typically mounted at /sys/fs/cgroup
	fullPath := filepath.Join("/sys/fs/cgroup", cgroupPathStr)
	
	info, err := os.Stat(fullPath)
	if err != nil {
		return 0, fmt.Errorf("failed to stat cgroup path %s: %w", fullPath, err)
	}
	
	// Get the inode number (this is the cgroup ID)
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return 0, fmt.Errorf("failed to get stat info")
	}
	
	return stat.Ino, nil
}

