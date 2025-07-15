require "json"

struct PaymentRequest
  include JSON::Serializable

  property correlationId : String?
  property amount : Float64?
end

struct PaymentProcessorRequest
  include JSON::Serializable
  property correlationId : String
  property amount : Float64
  property requestedAt : String?

  def initialize(@correlationId : String, @amount : Float64, @requestedAt : String?)
    @requestedAt = requestedAt.try(&.utc.to_s("%Y-%m-%dT%H:%M:%S.%LZ"))
  end
end