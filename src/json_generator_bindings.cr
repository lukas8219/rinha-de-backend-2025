@[Link(ldflags: "#{__DIR__}/lib/json_generator.o")]
lib LibJsonGenerator
  # Fast JSON generation for payment summary
  fun generate_payment_summary_json = generate_payment_summary_json(
    default_requests : Int32, 
    default_amount : Float64,
    fallback_requests : Int32, 
    fallback_amount : Float64
  ) : UInt8*
end

# Crystal wrapper for easy usage
module FastJsonGenerator
  def self.payment_summary(default_requests : Int32, default_amount : Float64, 
                          fallback_requests : Int32, fallback_amount : Float64) : String
    # Call C function
    c_string = LibJsonGenerator.generate_payment_summary_json(
      default_requests, default_amount, fallback_requests, fallback_amount
    )
    
    # Convert to Crystal string and free C memory
    if c_string.null?
      raise "Failed to generate JSON"
    end
    
    result = String.new(c_string)
    LibC.free(c_string.as(Void*))
    result
  end
end 