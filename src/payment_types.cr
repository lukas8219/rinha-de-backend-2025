require "json"

struct PaymentRequest
  include JSON::Serializable

  property correlationId : String?
  property amount : Float64?
  property description : String?
end

struct Payment
  include JSON::Serializable

  property correlationId : String
  property amount : Float64
  property description : String
  property timestamp : String

  def initialize(@correlationId : String, @amount : Float64, @description : String, @timestamp : String)
  end

  def to_bson
    {
      "correlationId" => @correlationId,
      "amount" => @amount,
      "description" => @description,
      "timestamp" => @timestamp
    }
  end
end 