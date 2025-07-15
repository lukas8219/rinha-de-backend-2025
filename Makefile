CRYSTAL_BIN ?= crystal
SHARDS_BIN ?= shards

.PHONY: deps build run-server run-consumer clean dev-server dev-consumer

# Install dependencies only if shard.yml changed or lib doesn't exist
lib: shard.yml
	$(SHARDS_BIN) install
	@touch lib

deps: lib

build: lib
	$(CRYSTAL_BIN) build src/rinha-2025.cr -o bin/server
	$(CRYSTAL_BIN) build src/consumer.cr -o bin/consumer

run-server: build
	./bin/server

run-consumer: build
	./bin/consumer

clean:
	rm -rf bin/
	rm -rf lib/

dev-server: lib
	$(CRYSTAL_BIN) run src/server.cr

dev-consumer: lib
	$(CRYSTAL_BIN) run src/consumer.cr 

download-perf-tooling:
	wget https://raw.githubusercontent.com/brendangregg/FlameGraph/refs/heads/master/flamegraph.pl -O profiling-data/flamegraph.pl
	wget https://raw.githubusercontent.com/brendangregg/FlameGraph/refs/heads/master/stackcollapse-perf.pl -O profiling-data/stackcollapse-perf.pl