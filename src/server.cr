require "kemal"
require "json"
require "./mongo_client"
require "./payment_types"
require "./circuit_breaker_wrapper"
require "./amqp/pubsub-client"

circuit_breaker_wrapper = CircuitBreakerWrapper.new(
  ENV["PROCESSOR_URL"]?.try(&.presence).nil? ? nil : HttpClient.new(ENV["PROCESSOR_URL"]),
  ENV["FALLBACK_URL"]?.try(&.presence).nil? ? nil : HttpClient.new(ENV["FALLBACK_URL"])
)

pubsub_client = PubSubClient.new(ENV["AMQP_URL"]?.not_nil!)

# Enable CORS
before_all do |env|
  env.response.headers.add "Access-Control-Allow-Origin", "*"
  env.response.headers.add "Access-Control-Allow-Methods", "GET, POST, OPTIONS"
  env.response.headers.add "Access-Control-Allow-Headers", "Content-Type"
end

options "/*" do |env|
  env.response.status_code = 200
end

get "/payments-summary" do |env|
  env.response.content_type = "application/json"
  
  begin
    summary = {
      "default" => {
        "totalRequests" => 0,
        "totalAmount" => 0
    },
    "fallback" => {
        "totalRequests" => 0,
        "totalAmount" => 0
    }
    }
    summary.to_json
  rescue ex
    env.response.status_code = 500
    {"error" => "Internal Server Error"}.to_json
  end
end

post "/payments" do |env|
  env.response.content_type = "application/json"
  
  begin
    if ENV["USE_CIRCUIT_BREAKER"]?
      #TODO stop parsing the body and use the circuit breaker wrapper directly
      response = circuit_breaker_wrapper.send_payment(env.request.body.not_nil!, nil)
      env.response.status_code = response.status_code
      next response.body
      return
    end

    payment_data = PaymentRequest.from_json(env.request.body.not_nil!)
    
    new_payment = Payment.new(
      correlationId: payment_data.correlationId.not_nil!,
      amount: payment_data.amount.not_nil!,
    )

    # Insert into MongoDB
    mongo_client = MongoClient.instance
    collection = mongo_client.db("challenge").collection("requested_payments")
    payment_json = new_payment.to_json
    collection.insert_one(new_payment.to_bson)
    pubsub_client.publish(payment_json)

    env.response.status_code = 201
    payment_json
    
  rescue JSON::ParseException
    env.response.status_code = 400
    {"error" => "Invalid JSON"}.to_json
  rescue ex
    env.response.status_code = 500
    {"error" => "Unexpected Error", "message" => ex.message}.to_json
  end
end

# Start the server
port = ENV["PORT"]?.try(&.to_i) || 3000
puts "HTTP Server running on port #{port}"
puts "GET /payment-summary - Get payment summary"
puts "POST /payments - Create a new payment"

Kemal.run(port) 