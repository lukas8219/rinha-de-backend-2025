FROM 84codes/crystal:latest-ubuntu-24.04 AS builder
RUN apt-get update && apt-get install -y liblz4-dev dpkg-dev
WORKDIR /app
COPY shard.yml shard.lock ./
RUN shards install --production
RUN apt-get update && apt-get install -y libgcc-s1 libstdc++6 && apt install -y libsqlite3-dev && rm -rf /var/lib/apt/lists/*

# Copy the rest of the application code
COPY . .

# Create bin directory and build the application
RUN mkdir -p bin
RUN crystal build --release -o bin/server src/server.cr
RUN crystal build --release -o bin/consumer src/consumer.cr

# Debug image
FROM ubuntu:24.04 AS base
RUN apt-get update
RUN apt install -y libsqlite3-dev

# App image
FROM base AS app
COPY --from=builder /app/bin/server ./server
EXPOSE 3000
CMD [ "./server" ]

# Worker image
FROM base AS worker
COPY --from=builder /app/bin/consumer ./consumer
EXPOSE 3000
CMD [ "./consumer" ]


# Debug with perf
FROM ubuntu:24.04 AS debug

WORKDIR /app
ENV LINUX_VERSION=6.14.9
ENV NO_LIBBPF=1 NO_SLANG=1 NO_LIBPYTHON=1 NO_JEVENTS=1 NO_PERL=1
RUN apt-get update && apt-get install -y make gcc flex bison git wget
RUN apt install -y xz-utils
RUN apt install -y \
    pkg-config \
    libelf-dev \
    libdw-dev \
    libiberty-dev \
    libzstd-dev \
    libunwind-dev \
    libssl-dev \
    libslang2-dev \
    systemtap-sdt-dev \
    clang \
    python3 \
    python3-dev \
    libperl-dev \
    flex \
    bison \
    zlib1g-dev \
    binutils-dev \
    libtraceevent-dev;

RUN wget https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${LINUX_VERSION}.tar.xz
RUN tar -xf ./linux-${LINUX_VERSION}.tar.xz \ 
    && cd linux-${LINUX_VERSION}/tools/perf/ \ 
    && make -C . && make NO_LIBTRACEEVENT=1 NO_LIBBABELTRACE=1 NO_LIBPFM=1 NO_LIBUNWIND=1 NO_SLANG=1 NO_LIBPYTHON=1 NO_PERL=1 NO_LIBBPF=1 NO_NUMA=1 NO_JAVA=1 \
    && cp perf /usr/bin/perf

RUN apt install -y libsqlite3-dev sqlite3

# Copy the built binary from builder
COPY --from=builder /app/bin/server ./server

# Expose the port the app listens on
EXPOSE 3000

# Set environment variables
ENV CRYSTAL_ENV=production

# Run the application
CMD [ "./server" ]


