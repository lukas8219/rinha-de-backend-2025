require "json"

struct PaymentRequest
  include JSON::Serializable

  property correlationId : String?
  property amount : Float64?
end

struct Payment
  include JSON::Serializable

  property correlationId : String
  property amount : Float64

  def initialize(@correlationId : String, @amount : Float64)
  end

  def to_bson
    {
      "correlationId" => @correlationId,
      "amount" => @amount,
    }
  end
end 