# deque.cr
@[Link("ck")]
@[Link(ldflags: "#{__DIR__}/libck_wrapper.a")]
lib Ck
  # tipo opaco do ring - use alias for opaque structs
  alias CkRingT = Void*

  # cada slot do buffer
  struct CkRingBufferT
    value : Void*
  end

  # Wrapper functions instead of direct inline functions
  fun ck_ring_init_wrapper(
    ring   : CkRingT,
    size   : UInt32
  ) : Void

  fun ck_ring_enqueue_spmc_wrapper(
    ring   : CkRingT,
    buffer : CkRingBufferT*,
    entry  : Void*
  ) : Bool

  fun ck_ring_dequeue_spmc_wrapper(
    ring   : CkRingT,
    buffer : CkRingBufferT*,
    result : Void**
  ) : Bool

  fun ck_ring_size_wrapper(ring : CkRingT) : UInt32
  
  # Get the actual size of structures
  fun ck_ring_sizeof() : LibC::SizeT
  fun ck_ring_buffer_sizeof() : LibC::SizeT
end

class LockFreeDeque(T)
  @ring : Ck::CkRingT
  @buffer : Ck::CkRingBufferT*
  @capacity : Int32

  def initialize(min_capacity : Int)
    # round‑up pra potência de 2
    cap = 1 << ((min_capacity - 1).bit_length)
    @capacity = cap.to_i32

    # Get actual struct sizes from C
    ring_size = Ck.ck_ring_sizeof()
    buffer_size = Ck.ck_ring_buffer_sizeof()
    
    # aloca o ring e o buffer
    @ring = LibC.malloc(ring_size).as(Ck::CkRingT)
    @buffer = LibC.malloc(buffer_size * cap)
                   .as(Ck::CkRingBufferT*)

    # Check allocation success
    if @ring.null? || @buffer.null?
      raise "Failed to allocate memory for ConcurrencyKit ring buffer"
    end

    # inicializa o ring usando wrapper
    Ck.ck_ring_init_wrapper(@ring, cap.to_u32)
  end

  # push (enqueue) retorna false se cheio - now works with type T
  def push(item : T) : Bool
    # Allocate memory for the item and store it using LibC.malloc
    item_ptr = LibC.malloc(sizeof(T)).as(Pointer(T))
    item_ptr.value = item
    
    success = Ck.ck_ring_enqueue_spmc_wrapper(@ring, @buffer, item_ptr.as(Void*))
    
    # If enqueue failed, free the allocated memory
    unless success
      LibC.free(item_ptr.as(Void*))
    end
    
    success
  end
  
  def <<(item : T) : Bool
    push(item)
  end

  # shift? (dequeue) retorna nil se vazio - now returns T?
  def shift? : T?
    # Use LibC.malloc for the result pointer to match LibC.free
    result_ptr = LibC.malloc(sizeof(Void*)).as(Pointer(Pointer(Void)))
    ok = Ck.ck_ring_dequeue_spmc_wrapper(@ring, @buffer, result_ptr.as(Void**))
    
    if ok
      # Get the void pointer and cast it back to T
      void_ptr = result_ptr.value
      LibC.free(result_ptr.as(Void*))
      
      if void_ptr.null?
        return nil
      end
      
      # Cast back to our type and get the value
      typed_ptr = void_ptr.as(Pointer(T))
      value = typed_ptr.value
      
      # Free the memory that was allocated in push
      LibC.free(typed_ptr.as(Void*))
      
      value
    else
      LibC.free(result_ptr.as(Void*))
      nil
    end
  end
  
  def shift : T?
    shift?
  end

  # empty? verifica tamanho == 0
  def empty? : Bool
    Ck.ck_ring_size_wrapper(@ring).zero?
  end
  
  def is_empty? : Bool
    empty?
  end

  # capacidade real (potência de 2)
  def capacity : Int32
    @capacity
  end

  # Memory cleanup
  def finalize
    # Note: We should ideally drain any remaining items to free their memory,
    # but that's complex to do safely during finalization
    LibC.free(@ring.as(Void*)) unless @ring.null?
    LibC.free(@buffer.as(Void*)) unless @buffer.null?
  end
end