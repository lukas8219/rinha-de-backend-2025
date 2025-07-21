require "./skiplist_bindings"

# Benchmark configuration
struct BenchmarkConfig
  property dataset_sizes : Array(Int32)
  property range_sizes : Array(Int32)
  property iterations : Int32

  def initialize
    @dataset_sizes = [10_000, 50_000, 100_000]
    @range_sizes = [100, 1_000, 10_000]
    @iterations = 5
  end
end

# Benchmark results
struct BenchmarkResult
  property dataset_size : Int32
  property range_size : Int32
  property avg_time_ms : Float64
  property min_time_ms : Float64
  property max_time_ms : Float64
  property elements_found : Int32

  def initialize(@dataset_size, @range_size, @avg_time_ms, @min_time_ms, @max_time_ms, @elements_found)
  end
end

class SkiplistBenchmark
  def initialize
    @config = BenchmarkConfig.new
    @results = Array(BenchmarkResult).new
  end

  def populate_skiplist(skiplist : Skiplist, size : Int32)
    puts "  Populating skiplist with #{size} elements..."
    
    # Generate random data with scores between 0.0 and 1000000.0
    # Elements are just the index values as integers
    populate_time = Time.measure do
      size.times do |i|
        score = rand() * 1_000_000.0
        element = i.to_i64
        skiplist.insert(score, element)
      end
    end
    
    puts "  Population completed in #{populate_time.total_milliseconds.round(2)}ms"
    puts "  Skiplist length: #{skiplist.length}"
  end

  def benchmark_range_scan(skiplist : Skiplist, dataset_size : Int32, range_size : Int32)
    puts "\n    Testing range scan with range_size: #{range_size}"
    
    # Calculate range bounds - scan from middle of dataset
    mid_score = 500_000.0
    half_range = (range_size * 100).to_f  # Convert to score range
    min_score = mid_score - half_range
    max_score = mid_score + half_range
    
    times = Array(Float64).new
    elements_found = 0
    
    @config.iterations.times do |iteration|
      # Add some variation to avoid cache effects
      variation = (iteration - 2) * 1000.0
      adjusted_min = min_score + variation
      adjusted_max = max_score + variation
      
      time = Time.measure do
        result = skiplist.range_scan(adjusted_min, adjusted_max)
        elements_found = result.size
      end
      
      times << time.total_milliseconds
      print "."
    end
    
    avg_time = times.sum / times.size
    min_time = times.min
    max_time = times.max
    
    puts " ✓"
    puts "      Avg: #{avg_time.round(3)}ms, Min: #{min_time.round(3)}ms, Max: #{max_time.round(3)}ms"
    puts "      Elements found: #{elements_found}"
    
    BenchmarkResult.new(dataset_size, range_size, avg_time, min_time, max_time, elements_found)
  end

  def run_benchmark_for_dataset(dataset_size : Int32)
    puts "\n=== Benchmarking Dataset Size: #{dataset_size} ==="
    
    skiplist = Skiplist.new
    populate_skiplist(skiplist, dataset_size)
    
    puts "\n  Starting range scan benchmarks..."
    
    @config.range_sizes.each do |range_size|
      result = benchmark_range_scan(skiplist, dataset_size, range_size)
      @results << result
    end
    
    # Test some edge cases
    puts "\n  Testing edge cases..."
    
    # Very small range
    puts "    Small range (10 elements expected):"
    small_time = Time.measure do
      result = skiplist.range_scan(500_000.0, 500_100.0)
      puts "      Found #{result.size} elements"
    end
    puts "      Time: #{small_time.total_milliseconds.round(3)}ms"
    
    # Very large range (most of dataset)
    puts "    Large range (most of dataset):"
    large_time = Time.measure do
      result = skiplist.range_scan(0.0, 1_000_000.0)
      puts "      Found #{result.size} elements"
    end
    puts "      Time: #{large_time.total_milliseconds.round(3)}ms"
    
    # Empty range
    puts "    Empty range:"
    empty_time = Time.measure do
      result = skiplist.range_scan(2_000_000.0, 3_000_000.0)
      puts "      Found #{result.size} elements"
    end
    puts "      Time: #{empty_time.total_milliseconds.round(3)}ms"
  end

  def run_full_benchmark
    puts "🚀 Starting Skiplist Range Scan Benchmark"
    puts "Configuration:"
    puts "  Dataset sizes: #{@config.dataset_sizes}"
    puts "  Range sizes: #{@config.range_sizes}"
    puts "  Iterations per test: #{@config.iterations}"
    
    total_time = Time.measure do
      @config.dataset_sizes.each do |dataset_size|
        run_benchmark_for_dataset(dataset_size)
      end
    end
    
    puts "\n" + "="*60
    puts "📊 BENCHMARK RESULTS SUMMARY"
    puts "="*60
    
    print_results_table()
    
    puts "\n🏁 Total benchmark time: #{total_time.total_seconds.round(2)} seconds"
  end

  private def print_results_table
    puts "\n| Dataset Size | Range Size | Avg Time (ms) | Min Time (ms) | Max Time (ms) | Elements Found |"
    puts "|--------------|------------|---------------|---------------|---------------|----------------|"
    
    @results.each do |result|
      printf("| %10s | %8s | %11.3f | %11.3f | %11.3f | %12s |\n",
        "#{result.dataset_size}K".sub("000K", "K"),
        result.range_size.to_s,
        result.avg_time_ms,
        result.min_time_ms,
        result.max_time_ms,
        result.elements_found.to_s
      )
    end
    
    # Performance analysis
    puts "\n📈 Performance Analysis:"
    
    # Group by range size to analyze scaling
    @config.range_sizes.each do |range_size|
      range_results = @results.select { |r| r.range_size == range_size }
      next if range_results.empty?
      
      puts "\nRange size #{range_size}:"
      range_results.each do |result|
        elements_per_ms = result.elements_found / result.avg_time_ms
        puts "  #{result.dataset_size}K dataset: #{elements_per_ms.round(0)} elements/ms"
      end
    end
    
    # Find best and worst performance
    if @results.size > 0
      fastest = @results.min_by(&.avg_time_ms)
      slowest = @results.max_by(&.avg_time_ms)
      
      puts "\n🏆 Fastest: #{fastest.dataset_size}K dataset, range #{fastest.range_size} - #{fastest.avg_time_ms.round(3)}ms"
      puts "🐌 Slowest: #{slowest.dataset_size}K dataset, range #{slowest.range_size} - #{slowest.avg_time_ms.round(3)}ms"
      
      speedup = slowest.avg_time_ms / fastest.avg_time_ms
      puts "⚡ Speedup ratio: #{speedup.round(1)}x"
    end
  end
end

# Memory usage helper
def print_memory_info(label : String)
  GC.collect
  stats = GC.stats
  puts "#{label} - Memory: #{(stats.heap_size / 1024 / 1024).round(1)}MB"
end

# Run the benchmark
if PROGRAM_NAME.includes?("skiplist_benchmark")
  puts "Starting memory measurement..."
  print_memory_info("Before benchmark")
  
  benchmark = SkiplistBenchmark.new
  benchmark.run_full_benchmark
  
  print_memory_info("After benchmark")
  
  puts "\n✅ Benchmark completed!"
end 