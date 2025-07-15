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
    # Both 'from' and 'to' query parameters are required
    from_param = env.params.query["from"]?
    to_param = env.params.query["to"]?

    unless from_param && to_param
      env.response.status_code = 400
      next({"error" => "'from' and 'to' query parameters are required in ISO8601 format"}.to_json)
    end

    begin
      from_time = Time.parse_iso8601(from_param)
      to_time = Time.parse_iso8601(to_param)
    rescue ex
      env.response.status_code = 400
      next({"error" => "Invalid 'from' or 'to' timestamp format. Use ISO8601."}.to_json)
    end

    mongo_client = MongoClient.instance
    collection = mongo_client.db("challenge").collection("processed_payments")

    # Build the match stage for the pipeline with both from and to
    match_stage = {
      "timestamp" => { "$gte" => from_time, "$lte" => to_time }
    }

    pipeline = [
      BSON.new({ "$match" => match_stage }),
      BSON.new({
        "$group" => {
          "_id" => "$processor",
          "totalRequests" => { "$sum" => 1 },
          "totalAmount" => { "$sum" => "$amount" }
        }
      })
    ]

    result = collection.aggregate(pipeline)
    summary = {
      "default" => { "totalRequests" => 0, "totalAmount" => 0.0 },
      "fallback" => { "totalRequests" => 0, "totalAmount" => 0.0 }
    }
    result.not_nil!.each do |doc|
      processor = doc["_id"].to_s
      summary[processor] = {
        "totalRequests" => doc["totalRequests"].as(Int32).to_i,
        "totalAmount" => doc["totalAmount"].as(Float64).to_f
      }
    end
    summary.to_json
  rescue ex
    env.response.status_code = 500
    {"error" => "Internal Server Error"}.to_json
  end
end

post "/payments" do |env|
  env.response.content_type = "application/json"
  
  begin
    {% if flag?(:skip_circuit_breaker) %}
      response = circuit_breaker_wrapper.send_payment(env.request.body.not_nil!, nil)
      env.response.status_code = response["response"].as(HTTP::Client::Response).status_code
      next response["response"].as(HTTP::Client::Response).body
      return
    {% end %}
    pubsub_client.publish(env.request.body.not_nil!)
    env.response.status_code = 201    
  rescue JSON::ParseException
    env.response.status_code = 400
  rescue ex
    env.response.status_code = 500
  end
end

# Start the server
port = ENV["PORT"]?.try(&.to_i) || 3000
puts "HTTP Server running on port #{port}"
puts "GET /payment-summary - Get payment summary"
puts "POST /payments - Create a new payment"

Kemal.run(port) 