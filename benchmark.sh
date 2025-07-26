#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
NGINX_URL="http://localhost:9999"
PINGORA_URL="http://localhost:9998"
HEALTHCHECK_PATH="/healthcheck"
DURATION="30s"
CONNECTIONS="100"
THREADS="4"

# Check if wrk is installed
if ! command -v wrk &> /dev/null; then
    echo -e "${RED}wrk is not installed. Please install it first:${NC}"
    echo "  macOS: brew install wrk"
    echo "  Ubuntu/Debian: sudo apt-get install wrk"
    echo "  Or build from source: https://github.com/wg/wrk"
    exit 1
fi

# Function to wait for service to be ready
wait_for_service() {
    local url=$1
    local service_name=$2
    local max_attempts=30
    local attempt=1
    
    echo -e "${YELLOW}Waiting for $service_name to be ready...${NC}"
    
    while [ $attempt -le $max_attempts ]; do
        if curl -s -o /dev/null -w "%{http_code}" "$url$HEALTHCHECK_PATH" | grep -q "200"; then
            echo -e "${GREEN}$service_name is ready!${NC}"
            return 0
        fi
        echo "Attempt $attempt/$max_attempts: $service_name not ready yet..."
        sleep 2
        ((attempt++))
    done
    
    echo -e "${RED}$service_name failed to become ready after $max_attempts attempts${NC}"
    return 1
}

# Function to run benchmark
run_benchmark() {
    local url=$1
    local service_name=$2
    
    echo -e "${BLUE}=== Benchmarking $service_name ===${NC}"
    echo "URL: $url$HEALTHCHECK_PATH"
    echo "Duration: $DURATION"
    echo "Connections: $CONNECTIONS"
    echo "Threads: $THREADS"
    echo ""
    
    # Run the benchmark and capture output
    local result=$(wrk -t$THREADS -c$CONNECTIONS -d$DURATION --latency "$url$HEALTHCHECK_PATH" 2>&1)
    
    echo "$result"
    echo ""
    
    # Extract key metrics
    local rps=$(echo "$result" | grep "Requests/sec:" | awk '{print $2}')
    local avg_latency=$(echo "$result" | grep "Latency" | head -1 | awk '{print $2}')
    local p99_latency=$(echo "$result" | grep "99%" | awk '{print $2}')
    
    # Store results for comparison
    if [ "$service_name" = "NGINX" ]; then
        nginx_rps=$rps
        nginx_avg_latency=$avg_latency
        nginx_p99_latency=$p99_latency
    else
        pingora_rps=$rps
        pingora_avg_latency=$avg_latency
        pingora_p99_latency=$p99_latency
    fi
}

# Function to compare results
compare_results() {
    echo -e "${BLUE}=== COMPARISON RESULTS ===${NC}"
    echo ""
    
    printf "%-20s %-15s %-15s %-15s\n" "Metric" "NGINX" "Pingora" "Difference"
    printf "%-20s %-15s %-15s %-15s\n" "--------------------" "---------------" "---------------" "---------------"
    
    # Requests per second
    if [[ $nginx_rps =~ ^[0-9]+\.?[0-9]*$ ]] && [[ $pingora_rps =~ ^[0-9]+\.?[0-9]*$ ]]; then
        local rps_diff=$(echo "scale=2; $pingora_rps - $nginx_rps" | bc -l 2>/dev/null || echo "N/A")
        local rps_percent=$(echo "scale=2; ($pingora_rps - $nginx_rps) / $nginx_rps * 100" | bc -l 2>/dev/null || echo "N/A")
        printf "%-20s %-15s %-15s %-15s\n" "Requests/sec" "$nginx_rps" "$pingora_rps" "+$rps_diff (+$rps_percent%)"
    else
        printf "%-20s %-15s %-15s %-15s\n" "Requests/sec" "$nginx_rps" "$pingora_rps" "N/A"
    fi
    
    # Average latency
    printf "%-20s %-15s %-15s %-15s\n" "Avg Latency" "$nginx_avg_latency" "$pingora_avg_latency" "Lower is better"
    
    # P99 latency
    printf "%-20s %-15s %-15s %-15s\n" "P99 Latency" "$nginx_p99_latency" "$pingora_p99_latency" "Lower is better"
    
    echo ""
    
    # Determine winner
    if [[ $nginx_rps =~ ^[0-9]+\.?[0-9]*$ ]] && [[ $pingora_rps =~ ^[0-9]+\.?[0-9]*$ ]]; then
        if (( $(echo "$pingora_rps > $nginx_rps" | bc -l) )); then
            echo -e "${GREEN}🏆 Pingora wins with higher RPS!${NC}"
        elif (( $(echo "$nginx_rps > $pingora_rps" | bc -l) )); then
            echo -e "${GREEN}🏆 NGINX wins with higher RPS!${NC}"
        else
            echo -e "${YELLOW}🤝 It's a tie!${NC}"
        fi
    fi
}

# Main execution
echo -e "${BLUE}=== NGINX vs Pingora Benchmark ===${NC}"
echo ""

# Check if services are running
wait_for_service "$NGINX_URL" "NGINX"
nginx_ready=$?

wait_for_service "$PINGORA_URL" "Pingora" 
pingora_ready=$?

if [ $nginx_ready -ne 0 ] && [ $pingora_ready -ne 0 ]; then
    echo -e "${RED}Both services are not ready. Please start them first.${NC}"
    echo "Run: docker-compose up -d"
    exit 1
fi

echo ""

# Run benchmarks
if [ $nginx_ready -eq 0 ]; then
    run_benchmark "$NGINX_URL" "NGINX"
else
    echo -e "${YELLOW}Skipping NGINX benchmark (service not ready)${NC}"
    nginx_rps="N/A"
    nginx_avg_latency="N/A"
    nginx_p99_latency="N/A"
fi

docker-compose restart

if [ $pingora_ready -eq 0 ]; then
    run_benchmark "$PINGORA_URL" "Pingora"
else
    echo -e "${YELLOW}Skipping Pingora benchmark (service not ready)${NC}"
    pingora_rps="N/A"
    pingora_avg_latency="N/A"
    pingora_p99_latency="N/A"
fi

# Compare results if both ran
if [ $nginx_ready -eq 0 ] && [ $pingora_ready -eq 0 ]; then
    compare_results
fi

echo -e "${BLUE}Benchmark completed!${NC}" 