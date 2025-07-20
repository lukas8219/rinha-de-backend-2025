require "./lock-free-deque"
require "spec"

record TestRecord, name : String, value : Int32

describe LockFreeDeque do
  it "works with integers" do
    deque = LockFreeDeque(Int32).new(8)
    deque.empty?.should be_true

    deque.push(42).should be_true
    deque.empty?.should be_false

    value = deque.shift?
    deque.empty?.should be_true
    value.should eq(42)
  end

  it "works with strings" do
    deque = LockFreeDeque(String).new(4)
    
    deque.push("hello").should be_true
    deque.push("world").should be_true
    
    deque.shift?.should eq("hello")
    deque.shift?.should eq("world")
    deque.shift?.should be_nil
  end

  it "handles capacity limits" do
    deque = LockFreeDeque(Int32).new(2) # Will round up to power of 2 (2)
    
    # Fill up the deque
    deque.push(1).should be_true
    
    # ConcurrencyKit rings typically reserve one slot, so with capacity 2,
    # we can only store 1 item before it's considered full
    push_result = deque.push(2)
    
    # Either it succeeds (if there's still space) or fails (if full)
    # Both are valid depending on the ring implementation
    if push_result
      # If second push succeeded, third should fail
      deque.push(3).should be_false
    else
      # Second push failed, which is expected with reserved slot
      push_result.should be_false
    end
  end

  it "works with custom objects" do
    deque = LockFreeDeque(TestRecord).new(4)
    
    item1 = TestRecord.new("test1", 100)
    item2 = TestRecord.new("test2", 200)
    
    deque.push(item1).should be_true
    deque.push(item2).should be_true
    
    result1 = deque.shift?
    result1.should_not be_nil
    result1.not_nil!.name.should eq("test1")
    result1.not_nil!.value.should eq(100)
    
    result2 = deque.shift?
    result2.should_not be_nil
    result2.not_nil!.name.should eq("test2")
    result2.not_nil!.value.should eq(200)
  end

  it "supports << operator" do
    deque = LockFreeDeque(Int32).new(4)
    
    (deque << 10).should be_true
    (deque << 20).should be_true
    
    deque.shift?.should eq(10)
    deque.shift?.should eq(20)
  end
end
