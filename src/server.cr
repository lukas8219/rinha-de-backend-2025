require "kemal"
require "json"
require "./payment_types"
require "./amqp/pubsub-client"
require "./sqlite_client"
require "big"

Log.setup_from_env

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

TO_CONSTANT = "3000-01-01T00:00:00Z"
FROM_CONSTANT = "1970-01-01T00:00:00Z"

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
    from_param = env.params.query["from"]?
    to_param = env.params.query["to"]?

    unless from_param && to_param
      from_param = FROM_CONSTANT
      to_param = TO_CONSTANT
    end
    # Build the match stage for the pipeline with both from and to
    summary = Summary.new(nil, nil)
    SqliteClient.instance.query_summary(from_param.not_nil!, to_param.not_nil!) do |rs|
      rs.each do
        # An easier way is to use a Hash to map processor to SummaryStats, then assign to Summary at the end.
        processor = rs.read(String)
        total_requests = rs.read(Int32)
        total_amount = rs.read(Float64)
        if processor == "default"
          summary.default ||= SummaryStats.new(total_requests, total_amount)
        else
          summary.fallback ||= SummaryStats.new(total_requests, total_amount)
        end
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