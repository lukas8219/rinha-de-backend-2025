require "benchmark"
require "json"
require "./json_generator_bindings"

# Old Crystal approach - simulating the original method
def generate_json_crystal(default_requests : Int32, default_amount : Float64, 
                         fallback_requests : Int32, fallback_amount : Float64) : String
  {
    "default" => { "totalRequests" => default_requests, "totalAmount" => default_amount },
    "fallback" => { "totalRequests" => fallback_requests, "totalAmount" => fallback_amount }
  }.to_json
end

# New C approach
def generate_json_c(default_requests : Int32, default_amount : Float64, 
                   fallback_requests : Int32, fallback_amount : Float64) : String
  FastJsonGenerator.payment_summary(default_requests, default_amount, fallback_requests, fallback_amount)
end

# Test data - realistic payment summary numbers
TEST_CASES = [
  {100, 1500.50, 25, 300.25},
  {0, 0.0, 0, 0.0},
  {999999, 123456.78, 888888, 987654.32},
  {1, 0.01, 1, 0.01},
  {50000, 75000.99, 10000, 15000.01}
]

puts "JSON Generation Benchmark: Crystal vs C"
puts "=" * 50

# First, verify both methods produce equivalent results
puts "\n🔍 Verifying correctness..."
TEST_CASES.each_with_index do |test_case, i|
  crystal_result = generate_json_crystal(*test_case)
  c_result = generate_json_c(*test_case)
  
  # Parse both to compare semantically (not string comparison due to potential formatting differences)
  crystal_parsed = JSON.parse(crystal_result)
  c_parsed = JSON.parse(c_result)
  
  if crystal_parsed == c_parsed
    puts "✅ Test case #{i + 1}: Results match"
  else
    puts "❌ Test case #{i + 1}: MISMATCH!"
    puts "  Crystal: #{crystal_result}"
    puts "  C:       #{c_result}"
    exit 1
  end
end

puts "\n🏃‍♂️ Running performance benchmarks..."
puts "\nWarmup phase..."

# Warmup both approaches
1000.times do
  generate_json_crystal(100, 1500.50, 25, 300.25)
  generate_json_c(100, 1500.50, 25, 300.25)
end

puts "\nBenchmarking with #{TEST_CASES.size} different test cases..."

# Run benchmark
Benchmark.ips do |x|
  x.report("Crystal JSON") do
    TEST_CASES.each { |test_case| generate_json_crystal(*test_case) }
  end
  
  x.report("C JSON") do
    TEST_CASES.each { |test_case| generate_json_c(*test_case) }
  end
end

puts "\n📊 Memory allocation test..."
puts "Generating 10,000 JSON responses with each method..."

# Memory test - count allocations
crystal_start = GC.stats.heap_size
10000.times { generate_json_crystal(100, 1500.50, 25, 300.25) }
GC.collect
crystal_end = GC.stats.heap_size

c_start = GC.stats.heap_size
10000.times { generate_json_c(100, 1500.50, 25, 300.25) }
GC.collect
c_end = GC.stats.heap_size

puts "Crystal approach heap growth: #{crystal_end - crystal_start} bytes"
puts "C approach heap growth: #{c_end - c_start} bytes"

# Sample output comparison
puts "\n📝 Sample output comparison:"
sample_crystal = generate_json_crystal(42, 123.45, 7, 67.89)
sample_c = generate_json_c(42, 123.45, 7, 67.89)

puts "Crystal: #{sample_crystal}"
puts "C:       #{sample_c}"
puts "Length difference: #{sample_c.size - sample_crystal.size} characters" 