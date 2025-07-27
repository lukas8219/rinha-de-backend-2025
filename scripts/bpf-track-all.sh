#!/bin/bash
BPFTRACE_MAX_BPF_PROGS="1000" BPFTRACE_MAX_PROBES="1000" bpftrace -e 'tracepoint:syscalls:sys_enter_* /comm == "server"/ {
  @[probe] = count();
}

kprobe:sock_*, kprobe:tcp_* /comm == "server"/ {
  @[probe] = count();
}'