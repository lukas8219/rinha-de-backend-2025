require "./amqp/pubsub-client"
require "json"
require "./circuit_breaker_wrapper"
require "./http_client"
require "./payment_types"
require "./sqlite_client"
require "./skiplist_bindings"
require "kemal"
require "./json_generator_bindings"

class Consumer
  @circuit_breaker : CircuitBreakerWrapper
  @processed_payments : DB::Database
  @pubsub_client : PubSubClient
  property default_skiplist : Skiplist
  property fallback_skiplist : Skiplist
  @default_mutex = Mutex.new
  @fallback_mutex = Mutex.new

  def initialize
    amqp_url = ENV["AMQP_URL"]? || "amqp://guest:guest@localhost:5672/"
    @pubsub_client = PubSubClient.new(amqp_url)
    process_client = HttpClient.new("default", @pubsub_client, ENV["PROCESSOR_URL"]? || "http://localhost:8001", 2000)
    fallback_client = HttpClient.new("fallback", @pubsub_client, ENV["FALLBACK_URL"]? || "http://localhost:8002", 5000)
    @circuit_breaker = CircuitBreakerWrapper.new(process_client, fallback_client)
    @processed_payments = SqliteClient.instance.db
    @default_skiplist = Skiplist.new
    @fallback_skiplist = Skiplist.new
  end

  def add_successful_payment(payment : PaymentProcessorRequest, processor : String)
    if processor == "default"
      @default_mutex.synchronize do
        @default_skiplist.insert(Time.parse_iso8601(payment.requestedAt.not_nil!).to_unix_ms.to_f, (payment.amount * 100.0).round.to_i64)
      end
    else
      @fallback_mutex.synchronize do
        @fallback_skiplist.insert(Time.parse_iso8601(payment.requestedAt.not_nil!).to_unix_ms.to_f, (payment.amount * 100.0).round.to_i64)
      end
    end
  end

  def run
    Log.info { "Listening for messages on AMQP queue: #{@pubsub_client.@queue_name}" }
    @pubsub_client.subscribe do |delivery|
      begin
        request = PaymentProcessorRequest.from_json(delivery.body_io.to_s)
        request.requestedAt = Time.utc.to_s("%Y-%m-%dT%H:%M:%S.%LZ")
        response = @circuit_breaker.send_payment(request, ENV["TOKEN"]?)
        if response.nil?
          @pubsub_client.publish(delivery.body_io)
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

hostname = ENV["HOSTNAME"]? || "consumer"
socket_sub_folder = ENV.fetch("SOCKET_SUB_FOLDER", "/dev/shm")
socket_path = "#{socket_sub_folder}/#{hostname}.sock"
SqliteClient.instance.insert_consumer(socket_path)
TO_CONSTANT = Time.parse_iso8601("3000-01-01T00:00:00Z").to_unix_ms.to_f
FROM_CONSTANT = Time.parse_iso8601("1970-01-01T00:00:00Z").to_unix_ms.to_f

get "/payments-summary" do |env|
  from_param_raw = env.params.query["from"]?
  to_param_raw = env.params.query["to"]?
  from_param = from_param_raw ? Time.parse_iso8601(from_param_raw).to_unix_ms.to_f : FROM_CONSTANT
  to_param = to_param_raw ? Time.parse_iso8601(to_param_raw).to_unix_ms.to_f : TO_CONSTANT
  #query internally and return results
  default_range = consumer.default_skiplist.range_scan(from_param, to_param)
  fallback_range = consumer.fallback_skiplist.range_scan(from_param, to_param)
  default_count = default_range.size
  default_sum = default_range.sum / 100.0
  fallback_count = fallback_range.size
  fallback_sum = fallback_range.sum / 100.0
  FastJsonGenerator.payment_summary(default_count, default_sum, fallback_count, fallback_sum)
end

# Remove the socket file if it already exists to avoid bind errors
if File.exists?(socket_path)
  File.delete(socket_path)
end

Fiber::ExecutionContext::Isolated.new("server") do
  Log.info { "Starting Kemal server" }
  Kemal.run do |config|
    config.server.not_nil!.bind_unix(socket_path)
    File.chmod(socket_path, 0o666)
  end
end

Fiber::ExecutionContext::Isolated.new("consumer") do
  consumer.run
end
   
loop do
  sleep 1.milliseconds
end