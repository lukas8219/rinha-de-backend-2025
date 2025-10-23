.PHONY: all clean

CLANG ?= clang
BPFTOOL ?= bpftool
ARCH := $(shell uname -m | sed 's/x86_64/x86/' | sed 's/aarch64/arm64/')

INCLUDES := -I/usr/include -I/usr/include/$(shell uname -m)-linux-gnu
CFLAGS := -g -O2 -target bpf -D__TARGET_ARCH_$(ARCH)

BPF_PROGS := c/tcp_connect.o c/network_traffic.o c/file_operations.o c/fork_tracker.o

all: vmlinux.h $(BPF_PROGS) 

c/%.o: c/%.c
	$(CLANG) $(CFLAGS) $(INCLUDES) -c $< -o $@

clean:
	rm -f c/*.o c/vmlinux.h

vmlinux.h:
	bpftool btf dump file /sys/kernel/btf/vmlinux format c > c/vmlinux.h

.PHONY: help
help:
	@echo "Usage:"
	@echo "  make          - Build all eBPF programs"
	@echo "  make clean    - Remove all compiled objects"

