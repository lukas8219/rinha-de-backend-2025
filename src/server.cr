require "kemal"
require "json"
require "./mongo_client"
require "./payment_types"

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
    # Check if we should proxy the request
    if ENV["PROXY_URL"]?
      # Proxy to another server
      response = HTTP::Client.post("#{ENV["PROXY_URL"]}/payments", 
        headers: HTTP::Headers{"Content-Type" => "application/json"},
        body: env.request.body.try(&.gets_to_end) || ""
      )
      env.response.status_code = response.status_code
      next response.body
    end

    # Parse the JSON body
    payment_data = PaymentRequest.from_json(env.request.body.not_nil!)
    
    # Validate the payment data
    if payment_data.amount.nil? || !payment_data.amount.is_a?(Number)
      env.response.status_code = 400
      next {"error" => "Amount is required and must be a number"}.to_json
    end

    # Create new payment
    new_payment = Payment.new(
      correlationId: payment_data.correlationId.not_nil!,
      amount: payment_data.amount.not_nil!,
    )

    # Insert into MongoDB
    mongo_client = MongoClient.instance
    collection = mongo_client.db("challenge").collection("requested_payments")
    collection.insert_one(new_payment.to_bson)

    env.response.status_code = 201
    new_payment.to_json
    
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