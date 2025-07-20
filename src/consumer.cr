require "./amqp/pubsub-client"
require "json"
require "./circuit_breaker_wrapper"
require "./http_client"
require "./payment_types"
require "./sqlite_client"
require "./skiplist_bindings"
require "kemal"

class Consumer
  @circuit_breaker : CircuitBreakerWrapper
  @processed_payments : DB::Database
  @pubsub_client : PubSubClient
  property default_skiplist : Skiplist
  property fallback_skiplist : Skiplist

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
      @default_skiplist.insert(Time.parse_iso8601(payment.requestedAt.not_nil!).to_unix_ms.to_f, (payment.amount * 100.0).round.to_i64)
    else
      @fallback_skiplist.insert(Time.parse_iso8601(payment.requestedAt.not_nil!).to_unix_ms.to_f, (payment.amount * 100.0).round.to_i64)
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

get "/state-summary" do |env|
  from_param_raw = env.params.query["from"]?
  to_param_raw = env.params.query["to"]?
  #query internally and return results
  default_range = consumer.default_skiplist.range_scan(from_param_raw.not_nil!.to_f, to_param_raw.not_nil!.to_f)
  fallback_range = consumer.fallback_skiplist.range_scan(from_param_raw.not_nil!.to_f, to_param_raw.not_nil!.to_f)
  default_count = default_range.size
  default_sum = default_range.sum
  fallback_count = fallback_range.size
  fallback_sum = fallback_range.sum
  { "default" => { "totalRequests" => default_count, "totalAmount" => default_sum }, "fallback" => { "totalRequests" => fallback_count, "totalAmount" => fallback_sum } }.to_json
end

# Remove the socket file if it already exists to avoid bind errors
if File.exists?(socket_path)
  File.delete(socket_path)
end

spawn do
  Log.info { "Starting Kemal server" }
  Kemal.run do |config|
    config.server.not_nil!.bind_unix(socket_path)
    File.chmod(socket_path, 0o666)
  end
end

consumer.run 
loop do
  sleep 1.seconds
end