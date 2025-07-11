FROM 84codes/crystal:latest-ubuntu-24.04 AS builder
RUN apt-get update && apt-get install -y liblz4-dev dpkg-dev
WORKDIR /app
COPY shard.yml shard.lock ./
RUN shards install --production

# Copy the rest of the application code
COPY . .

# Create bin directory and build the application
RUN mkdir -p bin
RUN crystal build --release --no-debug -o bin/server src/server.cr

# Final image - use ubuntu for compatibility with the built binary
FROM ubuntu:24.04

WORKDIR /app

# Install runtime dependencies
RUN apt-get update && apt-get install -y libgcc-s1 libstdc++6 net-tools && rm -rf /var/lib/apt/lists/*

# Copy the built binary from builder
COPY --from=builder /app/bin/server ./server

# Expose the port the app listens on
EXPOSE 3000

# Set environment variables
ENV CRYSTAL_ENV=production

# Run the application
ENTRYPOINT ["./server"]


