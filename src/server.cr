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

post "/admin/purge-database" do |env|
  env.response.content_type = "application/json"
  SqliteClient.instance.db.exec("DELETE FROM processed_payments;")
  env.response.status_code = 200
  {"message" => "Database purged"}.to_json
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