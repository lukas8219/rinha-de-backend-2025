require "kemal"
require "json"
require "./payment_types"
require "./amqp/pubsub-client"
require "./postgres_client"
require "big"

pubsub_client = PubSubClient.new(ENV["AMQP_URL"]? || "amqp://guest:guest@localhost:5672/")

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
  PostgresClient.instance.db.exec("DELETE FROM processed_payments;")
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
      from_param = "1970-01-01T00:00:00Z"
      to_param = "3000-01-01T00:00:00Z"
    end

    begin
      from_time = Time.parse_iso8601(from_param)
      to_time = Time.parse_iso8601(to_param)
    rescue ex
      env.response.status_code = 400
      next({"error" => "Invalid 'from' or 'to' timestamp format. Use ISO8601."}.to_json)
    end

    db = PostgresClient.instance.db

    # Build the match stage for the pipeline with both from and to
    summary = {
      "default" => { "totalRequests" => 0, "totalAmount" => 0.0 },
      "fallback" => { "totalRequests" => 0, "totalAmount" => 0.0 }
    }

    to_query_iso8601 = to_time.to_s("%Y-%m-%dT%H:%M:%S.%L%:z")
    from_query_iso8601 = from_time.to_s("%Y-%m-%dT%H:%M:%S.%L%:z")

    PostgresClient.instance.summary_query(from_query_iso8601, to_query_iso8601) do |rs|
      rs.each do
        Log.info { "Reading each result set" }
        processor = rs.read(String).strip
        total_requests = rs.read(Int64)
        total_amount = rs.read(PG::Numeric).to_f64
        summary[processor]["totalRequests"] += total_requests
        summary[processor]["totalAmount"] += total_amount
        Log.info { "processor: #{processor}, total_requests: #{total_requests}, total_amount: #{total_amount}" }
      end
    end
    summary.to_json
  rescue ex
    env.response.status_code = 500
    Log.error(exception: ex) { "Error getting payment summary" }
    {"error" => "Internal Server Error", "errorMessage" => ex.message}.to_json
  end
end

post "/payments" do |env|
  env.response.content_type = "application/json"
  
  begin
    pubsub_client.publish(env.request.body.not_nil!)
    env.response.status_code = 201    
  rescue ex : JSON::ParseException
    Log.error(exception: ex) { "Error parsing JSON" }
    env.response.status_code = 400
  rescue ex
    Log.error(exception: ex) { "Error processing payment" }
    env.response.status_code = 500
  end
end

# Start the server
port = ENV["PORT"]?.try(&.to_i) || 3000
Log.info { "HTTP Server running on port #{port}" }
Log.info { "GET /payment-summary - Get payment summary" }
Log.info { "POST /payments - Create a new payment" }

Kemal.run(port) 