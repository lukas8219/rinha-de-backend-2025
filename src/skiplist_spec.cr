require "./skiplist_bindings"
require "spec"

describe Skiplist do
  it "inserts elements and reports correct length" do
    skiplist = Skiplist.new
    skiplist.insert(1.0, 100_i64)
    skiplist.insert(3.0, 300_i64)
    skiplist.insert(2.0, 200_i64)
    skiplist.insert(4.0, 400_i64)
    skiplist.insert(1.5, 150_i64)
    skiplist.insert(2.5, 250_i64)
    skiplist.length.should eq(6)
  end

  it "counts elements in a score range" do
    skiplist = Skiplist.new
    skiplist.insert(1.0, 100_i64)
    skiplist.insert(3.0, 300_i64)
    skiplist.insert(2.0, 200_i64)
    skiplist.insert(4.0, 400_i64)
    skiplist.insert(1.5, 150_i64)
    skiplist.insert(2.5, 250_i64)
    skiplist.count(1.0, 3.0).should eq(5)
    skiplist.count(0.0, 10.0).should eq(6)
  end

  it "performs range scans correctly" do
    skiplist = Skiplist.new
    skiplist.insert(1.0, 100_i64)
    skiplist.insert(3.0, 300_i64)
    skiplist.insert(2.0, 200_i64)
    skiplist.insert(4.0, 400_i64)
    skiplist.insert(1.5, 150_i64)
    skiplist.insert(2.5, 250_i64)

    range = skiplist.range_scan(1.0, 3.0)
    range.size.should eq(5)
    range.elements.sort.should eq([100_i64, 150_i64, 200_i64, 250_i64, 300_i64])

    range2 = skiplist.range_scan(2.0, 4.0)
    range2.size.should eq(4)
    range2.elements.sort.should eq([200_i64, 250_i64, 300_i64, 400_i64])

    range3 = skiplist.range_scan(0.0, 10.0)
    range3.size.should eq(6)
    range3.elements.sort.should eq([100_i64, 150_i64, 200_i64, 250_i64, 300_i64, 400_i64])
  end

  it "deletes elements and updates length and range" do
    skiplist = Skiplist.new
    skiplist.insert(1.0, 100_i64)
    skiplist.insert(3.0, 300_i64)
    skiplist.insert(2.0, 200_i64)
    skiplist.insert(4.0, 400_i64)
    skiplist.insert(1.5, 150_i64)
    skiplist.insert(2.5, 250_i64)

    skiplist.delete(2.0, 200_i64).should be_true
    skiplist.length.should eq(5)
    skiplist.count(1.0, 3.0).should eq(4)
    range = skiplist.range_scan(1.0, 3.0)
    range.size.should eq(4)
    range.elements.sort.should eq([100_i64, 150_i64, 250_i64, 300_i64])
  end

  it "handles edge cases for range scan" do
    skiplist = Skiplist.new
    skiplist.insert(1.0, 100_i64)
    skiplist.insert(3.0, 300_i64)
    skiplist.insert(2.0, 200_i64)
    skiplist.insert(4.0, 400_i64)
    skiplist.insert(1.5, 150_i64)
    skiplist.insert(2.5, 250_i64)

    empty_range = skiplist.range_scan(10.0, 20.0)
    empty_range.size.should eq(0)

    single_range = skiplist.range_scan(1.5, 1.5)
    single_range.size.should eq(1)
    single_range.elements.should eq([150_i64])
    single_range.scores.should eq([1.5])
  end
end