require "./skiplist_bindings"

puts "🔬 SIMD Verification Test"
puts "========================"

# Print initial SIMD status
puts "\n📊 Initial SIMD Status:"
Skiplist.print_simd_status

# Create skiplist and add test data
skiplist = Skiplist.new
puts "\n🏗️  Building test dataset..."

# Add enough data to trigger SIMD (need 8+ elements for SIMD activation)
(1..1000).each do |i|
  skiplist.insert(i.to_f, i.to_i64)
end

puts "✅ Added 1000 elements"

# Test small range (should use scalar)
puts "\n🔍 Testing small range (should use scalar)..."
small_range = skiplist.range_scan(100.0, 105.0)
puts "   Found #{small_range.size} elements"

# Test large range (should use SIMD if supported)
puts "\n⚡ Testing large range (should use SIMD)..."
large_range = skiplist.range_scan(200.0, 800.0)
puts "   Found #{large_range.size} elements"

# Test very large range (definitely should use SIMD)
puts "\n🚀 Testing very large range (definitely SIMD)..."
huge_range = skiplist.range_scan(1.0, 999.0)
puts "   Found #{huge_range.size} elements"

# Print final SIMD usage statistics
puts "\n📈 Final SIMD Usage Statistics:"
Skiplist.print_simd_status

puts "\n✅ SIMD test completed!" 