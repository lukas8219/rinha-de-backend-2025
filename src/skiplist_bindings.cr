@[Link(ldflags: "#{__DIR__}/../lib/c/libskiplist.a")]
@[Link("jemalloc")]
lib LibSkiplist
  # C structure definitions
  struct ZSkiplistLevel
    forward : ZSkiplistNode*
    span : UInt32
  end

  struct ZSkiplistNode
    score : Float64
    ele : Int64  # Changed from UInt8* to Int64 for integer storage
    backward : ZSkiplistNode*
    level : ZSkiplistLevel[0]
  end

  struct ZSkiplist
    header : ZSkiplistNode*
    tail : ZSkiplistNode*
    length : UInt64
    level : Int32
  end

  # Range scan result structure
  struct ZSkiplistRange
    elements : Int64*
    scores : Float64*
    count : UInt64
    capacity : UInt64
  end

  # C function bindings
  fun zslCreate = zslCreate() : ZSkiplist*
  fun zslFree = zslFree(zsl : ZSkiplist*) : Void
  fun zslInsert = zslInsert(zsl : ZSkiplist*, score : Float64, ele : Int64) : ZSkiplistNode*
  fun zslDelete = zslDelete(zsl : ZSkiplist*, score : Float64, ele : Int64) : Int32
  fun zslCount = zslCount(zsl : ZSkiplist*, min : Float64, max : Float64) : UInt64
  fun zslRange = zslRange(zsl : ZSkiplist*, min : Float64, max : Float64) : ZSkiplistRange*
  fun zslFreeRange = zslFreeRange(range : ZSkiplistRange*) : Void
  fun zslPrintSIMDStatus = zslPrintSIMDStatus() : Void
end

# Structure to hold range scan results in Crystal
struct SkiplistRangeResult
  property elements : Array(Int64)
  property scores : Array(Float64)

  def initialize(@elements : Array(Int64), @scores : Array(Float64))
  end

  def size
    @elements.size
  end

  def each
    @elements.each_with_index do |element, index|
      yield element, @scores[index]
    end
  end

  def sum
    @elements.sum { |element| element }
  end

  def each_with_score
    each { |element, score| yield element, score }
  end
end

# Crystal wrapper class for easier usage
class Skiplist
  def initialize
    @skiplist = LibSkiplist.zslCreate()
    raise "Failed to create skiplist" if @skiplist.null?
  end

  def insert(score : Float64, element : Int64)
    node = LibSkiplist.zslInsert(@skiplist, score, element.to_i64)
    !node.null?
  end

  def delete(score : Float64, element : Int64)
    result = LibSkiplist.zslDelete(@skiplist, score, element.to_i64)
    result == 1
  end

  def count(min : Float64, max : Float64) : UInt64
    LibSkiplist.zslCount(@skiplist, min, max)
  end

  def range_scan(min : Float64, max : Float64) : SkiplistRangeResult
    range_ptr = LibSkiplist.zslRange(@skiplist, min, max)
    raise "Range scan failed" if range_ptr.null?
    
    range = range_ptr.value
    elements = Array(Int64).new(range.count.to_i32) do |i|
      (range.elements + i).value
    end
    scores = Array(Float64).new(range.count.to_i32) do |i|
      (range.scores + i).value
    end
    
    # Free the C memory
    LibSkiplist.zslFreeRange(range_ptr)
    
    SkiplistRangeResult.new(elements, scores)
  end

  def length : UInt64
    @skiplist.value.length
  end

  def finalize
    LibSkiplist.zslFree(@skiplist) unless @skiplist.null?
  end

  def self.print_simd_status
    LibSkiplist.zslPrintSIMDStatus()
  end
end 