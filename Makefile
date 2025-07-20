CRYSTAL_BIN ?= crystal
SHARDS_BIN ?= shards
CC ?= gcc
CFLAGS ?= -O2 -fPIC -Wall

.PHONY: deps build run-server run-consumer clean dev-server dev-consumer build-skiplist test-skiplist benchmark-skiplist

# Install dependencies only if shard.yml changed or lib doesn't exist
lib: shard.yml
	$(SHARDS_BIN) install
	@touch lib

deps: lib

# Build the skiplist C library
build-skiplist:
	mkdir -p lib/c
	$(CC) $(CFLAGS) -c src/lib/skiplist.c -o lib/c/skiplist.o
	ar rcs lib/c/libskiplist.a lib/c/skiplist.o

build: lib build-skiplist
	$(CRYSTAL_BIN) build src/rinha-2025.cr -o bin/server
	$(CRYSTAL_BIN) build src/consumer.cr -o bin/consumer

run-server: build
	./bin/server

run-consumer: build
	./bin/consumer

clean:
	rm -rf bin/
	rm -rf lib/

dev-server: lib build-skiplist
	HOSTNAME=1 SHARD_COUNT=1 SOCKET_SUB_FOLDER=/tmp $(CRYSTAL_BIN) run src/server.cr

dev-consumer: lib build-skiplist
	HOSTNAME=1 SHARD_COUNT=1 SOCKET_SUB_FOLDER=/tmp $(CRYSTAL_BIN) run src/consumer.cr 

spec-skiplist: lib build-skiplist
	$(CRYSTAL_BIN) spec src/skiplist_spec.cr

benchmark-skiplist: lib build-skiplist
	$(CRYSTAL_BIN) run src/skiplist_benchmark.cr --release

download-perf-tooling:
	wget https://raw.githubusercontent.com/brendangregg/FlameGraph/refs/heads/master/flamegraph.pl -O profiling-data/flamegraph.pl
	wget https://raw.githubusercontent.com/brendangregg/FlameGraph/refs/heads/master/stackcollapse-perf.pl -O profiling-data/stackcollapse-perf.pl