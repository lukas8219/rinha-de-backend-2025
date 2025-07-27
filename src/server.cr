require "json"
require "./circuit_breaker_wrapper"
require "./http_client"
require "./payment_types"
require "./skiplist_bindings"
require "./json_generator_bindings"
require "http/server"
require "http"
require "./lib/pubsub_client"

class Consumer
  @circuit_breaker : CircuitBreakerWrapper
  property pubsub_client : PubSub::Client
  property default_skiplist : Skiplist
  property fallback_skiplist : Skiplist

  def initialize
    @pubsub_client = PubSub::Client.new()
    process_client = HttpClient.new("default", @pubsub_client, ENV["PROCESSOR_URL"]? || "http://localhost:8001", 2000)
    fallback_client = HttpClient.new("fallback", @pubsub_client, ENV["FALLBACK_URL"]? || "http://localhost:8002", 5000)
    @circuit_breaker = CircuitBreakerWrapper.new(process_client, fallback_client)
    @default_skiplist = Skiplist.new
    @fallback_skiplist = Skiplist.new
  end

  def add_successful_payment(payment : PaymentProcessorRequest, processor : String)
    if processor == "default"
      @default_skiplist.insert(Time.parse_iso8601(payment.requestedAt.not_nil!).to_unix_ms.to_f, (payment.amount * 100.0).round.to_i64)
    else
      @fallback_skiplist.insert(Time.parse_iso8601(payment.requestedAt.not_nil!).to_unix_ms.to_f, (payment.amount * 100.0).round.to_i64)
    end
  end

  def run
    Log.info { "Listening for messages on AMQP queue: #{@pubsub_client.inspect}" }
    @pubsub_client.subscribe_payments do |delivery|
      begin
        request = PaymentProcessorRequest.from_json(String.new(delivery))
        request.requestedAt = Time.utc.to_s("%Y-%m-%dT%H:%M:%S.%LZ")
        response = @circuit_breaker.send_payment(request, ENV["TOKEN"]?)
        if response.nil?
          @pubsub_client.reenqueue_payments(delivery)
        else 
          add_successful_payment(request, response["processor"].to_s)
        end
      rescue ex
        Log.error(exception: ex) { "Error processing message" }
      end
    end
  end

  def close
    @pubsub_client.close
  end
end

# Handle graceful shutdown
Signal::INT.trap do
  Log.info { "Shutting down consumer..." }
  exit(0)
end

# Start the consumer
consumer = Consumer.new

socket_path = ENV.fetch("SOCKET_PATH", "/dev/shm/consumer.sock")
TO_CONSTANT = Time.parse_iso8601("3000-01-01T00:00:00Z").to_unix_ms.to_f
FROM_CONSTANT = Time.parse_iso8601("1970-01-01T00:00:00Z").to_unix_ms.to_f
File.delete(socket_path) if File.exists?(socket_path)

class HTTPHandler
  include HTTP::Handler
  @pubsub_client : PubSub::Client
  @file : File
  
  def initialize(@consumer : Consumer)
    @pubsub_client = @consumer.pubsub_client
    @file = File.new("/dev/shm/consumer.sock", "w")
  end

  def call(context : HTTP::Server::Context) : Nil
    request = context.request
    response = context.response
    
    # Add CORS headers
    response.headers.add "Access-Control-Allow-Origin", "*"
    response.headers.add "Access-Control-Allow-Methods", "GET, POST, OPTIONS"
    response.headers.add "Access-Control-Allow-Headers", "Content-Type"
    response.headers.add "Connection", "no-keepalive"
    
    # Handle OPTIONS requests for CORS
    if request.method == "OPTIONS"
      response.status_code = 200
      return
    end
    
    # Route handling
    case {request.method, request.path}
    when {"GET", "/healthcheck"}
      handle_healthcheck(context)
    when {"POST", "/payments"}
      handle_payments(context)
    when {"GET", "/payments-summary"}
      handle_payments_summary(context)

    else
      response.status_code = 404
      response.content_type = "application/json"
      response.print({error: "Not Found"}.to_json)
    end
    
    # record_request_metrics(start_time, request, response)
  end
  
  private def handle_healthcheck(context : HTTP::Server::Context)
    context.response.status_code = 200
    context.response.content_type = "application/json"
    context.response.print({status: "ok"}.to_json)
  end

  private def handle_payments(context : HTTP::Server::Context)
    #stop expecting a json - let pingora send a byteIO of `string36:float`
    context.response.status_code = 200
    context.response.content_type = "application/json"
    context.request.body.not_nil!.gets_to_end
    "ok"
    # @pubsub_client.publish_payments(context.request.body.not_nil!)
    # @file.write(context.request.body.not_nil!.gets_to_end.to_slice)
  end
  
  private def handle_payments_summary(context : HTTP::Server::Context)
    query_params = context.request.query_params
    from_param_raw = query_params["from"]?
    to_param_raw = query_params["to"]?
    from_param = from_param_raw ? Time.parse_iso8601(from_param_raw).to_unix_ms.to_f : FROM_CONSTANT
    to_param = to_param_raw ? Time.parse_iso8601(to_param_raw).to_unix_ms.to_f : TO_CONSTANT
    
    # Query internally and return results
    default_range = @consumer.default_skiplist.range_scan(from_param, to_param)
    fallback_range = @consumer.fallback_skiplist.range_scan(from_param, to_param)
    default_count = default_range.size
    default_sum = default_range.sum / 100.0
    fallback_count = fallback_range.size
    fallback_sum = fallback_range.sum / 100.0
    
    context.response.status_code = 200
    context.response.content_type = "application/json"
    context.response.print FastJsonGenerator.payment_summary(default_count, default_sum, fallback_count, fallback_sum)
  end
end



port = ENV.fetch("PORT", "9999").to_i
Log.info { "Starting HTTP server" }

handler = HTTPHandler.new(consumer)
server = HTTP::Server.new([handler])

# Fiber::ExecutionContext::Isolated.new("consumer") do
#   consumer.run
# end

if ENV["USE_HTTP"]?
  Log.info { "Binding to TCP 0.0.0.0:#{port}" }
  server.bind_tcp("0.0.0.0", port, reuse_port: true)
else
  Log.info { "Binding to Unix socket: #{socket_path}" }
  server.bind_unix(socket_path)
  File.chmod(socket_path, 0o666)
end
server.listen
Log.info { "Server listening" }