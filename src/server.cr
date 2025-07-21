require "kemal"
require "json"
require "./payment_types"
require "./amqp/pubsub-client"
require "./sqlite_client"
require "./json_generator_bindings"
require "big"

pubsub_client = PubSubClient.new(ENV["AMQP_URL"]? || "amqp://guest:guest@localhost:5672/")

#init
SqliteClient.instance

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

TO_CONSTANT = Time.parse_iso8601("3000-01-01T00:00:00Z").to_unix_ms.to_f.to_s
FROM_CONSTANT = Time.parse_iso8601("1970-01-01T00:00:00Z").to_unix_ms.to_f.to_s

class Summary
  property default : SummaryStats?
  property fallback : SummaryStats?

  def initialize(@default : SummaryStats?, @fallback : SummaryStats?)
  end

  def to_json(builder : JSON::Builder)
    builder.object do
      builder.field "default", default || SummaryStats.new(0, 0.0)
      builder.field "fallback", fallback || SummaryStats.new(0, 0.0)
    end
  end
end

class SummaryStats
  property totalRequests : Int32
  property totalAmount : Float64

  def initialize(@totalRequests : Int32, @totalAmount : Float64)
  end

  def to_json(builder : JSON::Builder)
    builder.object do
      builder.field "totalRequests", totalRequests
      builder.field "totalAmount", totalAmount
    end
  end
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
    from_param_raw = env.params.query["from"]?
    to_param_raw = env.params.query["to"]?

    from_param = from_param_raw ? Time.parse_iso8601(from_param_raw).to_unix_ms.to_f.to_s : FROM_CONSTANT
    to_param = to_param_raw ? Time.parse_iso8601(to_param_raw).to_unix_ms.to_f.to_s : TO_CONSTANT
  
    # For each host, make a request to its /stats endpoint via UNIX socket
  
    stats_results = {
      "default" => { "totalRequests" => 0, "totalAmount" => 0 },
      "fallback" => { "totalRequests" => 0, "totalAmount" => 0 }
    } of String => Hash(String, Int32)
  
    SqliteClient.instance.get_consumer_clients.not_nil!.each do |client|
      response = client.get("/state-summary?from=#{from_param}&to=#{to_param}")
      if response.status_code == 200
        parsed_json = JSON.parse(response.body)
        stats_results["default"]["totalRequests"] += parsed_json["default"]["totalRequests"].as_i
        stats_results["default"]["totalAmount"] += parsed_json["default"]["totalAmount"].as_i
        stats_results["fallback"]["totalRequests"] += parsed_json["fallback"]["totalRequests"].as_i
        stats_results["fallback"]["totalAmount"] += parsed_json["fallback"]["totalAmount"].as_i
      end
    end
  
    env.response.status_code = 200
    # Use fast C JSON generator for maximum performance
    FastJsonGenerator.payment_summary(
      stats_results["default"]["totalRequests"], 
      stats_results["default"]["totalAmount"] / 100.0,
      stats_results["fallback"]["totalRequests"], 
      stats_results["fallback"]["totalAmount"] / 100.0
    )
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
port = ENV["PORT"]?.try(&.to_i) || 9999
Log.info { "HTTP Server running on port #{port}" }
Log.info { "GET /payment-summary - Get payment summary" }
Log.info { "POST /payments - Create a new payment" }

Kemal.run(port) do |config|
  if ENV["SOCKET_PATH"]?
    config.server.not_nil!.bind_unix(ENV["SOCKET_PATH"]?.not_nil!)
    File.chmod(ENV["SOCKET_PATH"]?.not_nil!, 0o666)
  else
    config.server.not_nil!.bind_tcp(port)
  end
end