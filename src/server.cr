require "kemal"
require "json"
require "./payment_types"
require "./amqp/pubsub-client"
require "./json_generator_bindings"
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

get "/healthcheck" do |env|
  env.response.status_code = 200
end

require "socket"

# Create an HTTP client that connects via a Unix socket
socket_path = ENV["DATABASE_URL"]? || "/dev/shm/1.sock"
unix_socket = UNIXSocket.new(socket_path)
database_client = HTTP::Client.new(unix_socket)

get "/payments-summary" do |env|
  env.response.content_type = "application/json"
  env.response.status_code = 200
  database_client.get("/payments-summary?#{env.request.query_params.to_s}").body
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
  socket_path = ENV["SOCKET_PATH"]?
  if socket_path
    if File.exists?(socket_path)
      File.delete(socket_path)
    end
    config.server.not_nil!.bind_unix(socket_path)
    File.chmod(socket_path, 0o666)
    Log.info { "HTTP Server running on socket #{socket_path}" }
  else
    config.server.not_nil!.bind_tcp(port)
  end
end