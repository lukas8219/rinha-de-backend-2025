require "kemal"
require "json"
require "./payment_types"
require "./circuit_breaker_wrapper"
require "./amqp/pubsub-client"
require "./sqlite_client"

pubsub_client = PubSubClient.new(ENV["AMQP_URL"]? || "amqp://guest:guest@localhost:5672/")

circuit_breaker_wrapper = CircuitBreakerWrapper.new(
  ENV["PROCESSOR_URL"]?.try(&.presence).nil? ? nil : HttpClient.new("default", pubsub_client, ENV["PROCESSOR_URL"]),
  ENV["FALLBACK_URL"]?.try(&.presence).nil? ? nil : HttpClient.new("fallback", pubsub_client, ENV["FALLBACK_URL"])
)

if ENV["DISABLE_LOG"]?
  logging false
end
# Enable CORS
before_all do |env|
  env.response.headers.add "Access-Control-Allow-Origin", "*"
  env.response.headers.add "Access-Control-Allow-Methods", "GET, POST, OPTIONS"
  env.response.headers.add "Access-Control-Allow-Headers", "Content-Type"
end

options "/*" do |env|
  env.response.status_code = 200
end

post "/admin/purge-database" do |env|
  env.response.content_type = "application/json"
  SqliteClient.instance.db.exec("DELETE FROM processed_payments;")
  env.response.status_code = 200
  {"message" => "Database purged"}.to_json
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

    sqlite_client = SqliteClient.instance
    db = sqlite_client.db

    # Build the match stage for the pipeline with both from and to
    summary = {
      "default" => { "totalRequests" => 0, "totalAmount" => 0.0 },
      "fallback" => { "totalRequests" => 0, "totalAmount" => 0.0 }
    }

    sql = <<-SQL
      SELECT processor, COUNT(*) AS totalRequests, COALESCE(SUM(amount), 0) AS totalAmount
      FROM processed_payments
      WHERE timestamp >= ? AND timestamp <= ?
      GROUP BY processor
    SQL

    db.query(sql, from_time.to_s("%Y-%m-%dT%H:%M:%S.%LZ"), to_time.to_s("%Y-%m-%dT%H:%M:%S.%LZ")) do |rs|
      rs.each do
        processor = rs.read(String)
        total_requests = rs.read(Int64)
        total_amount = rs.read(Float64)
        summary[processor] = {
          "totalRequests" => total_requests.to_i,
          "totalAmount" => total_amount.to_f
        }
      end
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
  rescue ex : JSON::ParseException
    puts "Error parsing JSON: #{ex.message}"
    env.response.status_code = 400
  rescue ex
    puts "Error processing payment: #{ex.message}"
    env.response.status_code = 500
  end
end

# Start the server
port = ENV["PORT"]?.try(&.to_i) || 3000
puts "HTTP Server running on port #{port}"
puts "GET /payment-summary - Get payment summary"
puts "POST /payments - Create a new payment"

Kemal.run(port) 