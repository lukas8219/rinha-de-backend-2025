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
  property requestedAt : Time?
end

struct Payment
  include JSON::Serializable

  property correlationId : String
  property amount : Float64
  property requestedAt : Time?

  def initialize(@correlationId : String, @amount : Float64, @requestedAt : Time?)
  end

  def to_bson
    {
      "correlationId" => @correlationId,
      "amount" => @amount,
      "requestedAt" => @requestedAt
    }
  end
end 