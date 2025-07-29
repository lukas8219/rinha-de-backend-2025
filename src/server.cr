require "kemal"
require "json"
require "./payment_types"
require "./amqp/pubsub-client"
require "./json_generator_bindings"
require "big"

# This is a hack to deal with this error
#app1-1      | 2025-07-28T23:49:06.555446Z  ERROR - Error processing payment
# app1-1      | Can't transfer fd=17 to another polling event loop with pending reader/writer fibers (RuntimeError)
# app1-1      |   from usr/share/crystal/src/crystal/system/unix/epoll.cr:15:13 in 'take_ownership'
# app1-1      |   from usr/share/crystal/src/crystal/event_loop/polling/waiters.cr:16:5 in 'unbuffered_write'
# app1-1      |   from usr/share/crystal/src/io/buffered.cr:252:5 in '??'
# app1-1      |   from app/lib/amqp-client/src/amqp-client/connection.cr:210:9 in 'basic_publish'
# app1-1      |   from app/src/server.cr:46:5 in '->'
# app1-1      |   from app/lib/kemal/src/kemal/route.cr:12:9 in '->'
# app1-1      |   from app/lib/kemal/src/kemal/route_handler.cr:52:39 in 'call'
# app1-1      |   from app/lib/kemal/src/kemal/filter_handler.cr:28:7 in 'call'
# app1-1      |   from app/lib/kemal/src/kemal/static_file_handler.cr:11:11 in 'call'
# app1-1      |   from usr/share/crystal/src/http/server/handler.cr:30:7 in 'call'
# app1-1      |   from usr/share/crystal/src/http/server/handler.cr:30:7 in 'call'
# app1-1      |   from usr/share/crystal/src/http/server/request_processor.cr:51:11 in 'handle_client'
# app1-1      |   from usr/share/crystal/src/fiber.cr:170:11 in 'run'
# app1-1      |   from ???
module PubSubManager
  @@pubsub_clients = [
    PubSubClient.new(ENV["AMQP_URL"]? || "amqp://guest:`guest@localhost:5672/"),
    PubSubClient.new(ENV["AMQP_URL"]? || "amqp://guest:`guest@localhost:5672/"),
    PubSubClient.new(ENV["AMQP_URL"]? || "amqp://guest:`guest@localhost:5672/"),
    PubSubClient.new(ENV["AMQP_URL"]? || "amqp://guest:`guest@localhost:5672/"),
  ] of PubSubClient

  @@counter = Atomic(Int32).new(0)

  def self.get_pubsub_client()
    @@pubsub_clients[@@counter.add(1, :relaxed) % @@pubsub_clients.size]
  end
end

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
    PubSubManager.get_pubsub_client.publish(env.request.body.not_nil!)
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