CRYSTAL_BIN ?= crystal
CRYSTAL_FLAGS ?= -Dgc_none
SHARDS_BIN ?= shards
CC ?= gcc
CFLAGS ?= -O3 -funroll-loops -DNDEBUG -fPIC -Wall -Wno-unused-function

.PHONY: deps build run-server run-consumer clean dev-server dev-consumer build-skiplist test-skiplist benchmark-skiplist

bin:
	mkdir -p bin

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

# Build the JSON generator C library
build-json-generator:
	$(CC) $(CFLAGS) -c src/lib/json_generator.c -o src/lib/json_generator.o

build-consumer: bin
	$(CRYSTAL_BIN) build src/consumer.cr $(CRYSTAL_FLAGS) -o bin/consumer

build-server: bin
	$(CRYSTAL_BIN) build src/server.cr $(CRYSTAL_FLAGS) -o bin/server

build: lib build-skiplist build-json-generator build-consumer build-server

run-server: build
	./bin/server

run-consumer: build
	./bin/consumer

clean:
	rm -rf bin/
	rm -rf lib/

dev-server: lib build-skiplist build-json-generator
	SOCKET_PATH=/tmp/app1.sock HOSTNAME=1 SHARD_COUNT=1 $(CRYSTAL_BIN) run src/server.cr

dev-consumer: lib build-skiplist build-json-generator
	SOCKET_PATH=/tmp/1.sock HOSTNAME=1 SHARD_COUNT=1 $(CRYSTAL_BIN) run -Dpreview_mt -Dexecution_context src/consumer.cr 

dev-pingora: lib build-skiplist build-json-generator
	RUST_LOG=debug cargo run --bin pingora-server

dev-pingora-help:
	RUST_LOG=debug cargo run --bin pingora-server -- --help

spec-skiplist: lib build-skiplist build-json-generator
	$(CRYSTAL_BIN) spec $(CRYSTAL_FLAGS) src/skiplist_spec.cr

benchmark-skiplist: lib build-skiplist build-json-generator
	$(CRYSTAL_BIN) run $(CRYSTAL_FLAGS) src/skiplist_benchmark.cr --release

benchmark-json: lib build-skiplist build-json-generator
	$(CRYSTAL_BIN) run $(CRYSTAL_FLAGS) src/json_benchmark.cr --release

download-perf-tooling:
	wget https://raw.githubusercontent.com/brendangregg/FlameGraph/refs/heads/master/flamegraph.pl -O profiling-data/flamegraph.pl
	wget https://raw.githubusercontent.com/brendangregg/FlameGraph/refs/heads/master/stackcollapse-perf.pl -O profiling-data/stackcollapse-perf.pl

# Benchmark targets for NGINX vs Pingora comparison
benchmark-nginx-pingora:
	@echo "Building and starting services..."
	docker-compose up -d --build
	@echo "Waiting for services to be ready..."
	sleep 15
	@echo "Running benchmark..."
	./benchmark.sh

benchmark-quick:
	@echo "Running quick benchmark (10s duration)..."
	DURATION=10s ./benchmark.sh

benchmark-long:
	@echo "Running long benchmark (60s duration)..."
	DURATION=60s ./benchmark.sh

stop-services:
	docker-compose down

logs-nginx:
	docker-compose logs -f nginx

logs-pingora:
	docker-compose logs -f pingora