require "./amqp/pubsub-client"
require "json"
require "./mongo_client"
require "./circuit_breaker_wrapper"
require "./http_client"
require "./payment_types"

class Consumer
  @circuit_breaker : CircuitBreakerWrapper
  @processed_payments : Mongo::Collection
  @successful_batches : Array(BSON)
  @last_insert : Time
  @pubsub_client : PubSubClient
  @array_mutex : Mutex

  def initialize
    amqp_url = ENV["AMQP_URL"]? || "amqp://guest:guest@localhost:5672/"
    @pubsub_client = PubSubClient.new(amqp_url)
    process_client = HttpClient.new("default", @pubsub_client, ENV["PROCESSOR_URL"]? || "http://localhost:8001")
    fallback_client = HttpClient.new("fallback", @pubsub_client, ENV["FALLBACK_URL"]? || "http://localhost:8002")
    @array_mutex = Mutex.new
    
    @circuit_breaker = CircuitBreakerWrapper.new(process_client, fallback_client)
    
    mongo_client = MongoClient.instance
    @processed_payments = mongo_client.db("challenge").collection("processed_payments")
    
    @successful_batches = [] of BSON
    @last_insert = Time.utc
    start_batch_timer
  end

  def start_batch_timer
    spawn do
      loop do
        trigger_process
        sleep 0.125.seconds # 125ms
      end
    end
  end

  def add_successful_payment(payment : PaymentProcessorRequest, processor : String)
    bson_doc = to_bson(payment, processor)
    if ENV["SKIP_BATCH"]?
      @processed_payments.insert_one(bson_doc)
    else
      @successful_batches << bson_doc
    end
  end

  def to_bson(payment : PaymentProcessorRequest, processor : String)
    BSON.new({
      "correlationId" => payment.correlationId,
      "amount" => payment.amount.to_f,
      "processor" => processor,
      "timestamp" => payment.requestedAt
    })
  end

  def trigger_process
    return if @successful_batches.empty?
    @array_mutex.lock

    puts "Starting Insert Batch"
    to_insert = @successful_batches.dup
    @successful_batches.clear
    @last_insert = Time.utc
    @array_mutex.unlock

    @processed_payments.insert_many(to_insert)
  end

  def run
    puts "Listening for messages on AMQP queue: #{@pubsub_client.@queue_name}"
    @pubsub_client.subscribe do |delivery|
      begin
        request = PaymentProcessorRequest.from_json(delivery.body_io.to_s)
        request.requestedAt = Time.utc
        response = @circuit_breaker.send_payment(request, ENV["TOKEN"]?)
        if response
          add_successful_payment(request, response["processor"].to_s)
        end
      rescue ex
        puts "Error processing message: #{ex.message}"
      end
    end
  end

  def close
    @pubsub_client.close
  end
end

# Handle graceful shutdown
Signal::INT.trap do
  puts "Shutting down consumer..."
  exit(0)
end

# Start the consumer
consumer = Consumer.new
consumer.run 
loop do
  sleep 1.seconds
end