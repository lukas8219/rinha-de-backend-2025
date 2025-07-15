require "./amqp/pubsub-client"
require "json"
require "./mongo_client"
require "./circuit_breaker_wrapper"
require "./http_client"
require "./payment_types"

class Consumer
  @circuit_breaker : CircuitBreakerWrapper
  @processed_payments : Mongo::Collection
  @successful_batches : Array(Hash(String, PaymentProcessorRequest | String))
  @last_insert : Time
  @pubsub_client : PubSubClient

  def initialize
    process_client = HttpClient.new(ENV["PROCESSOR_URL"]?.not_nil!)
    fallback_client = HttpClient.new(ENV["FALLBACK_URL"]?.not_nil!)
    
    @circuit_breaker = CircuitBreakerWrapper.new(process_client, fallback_client)
    
    mongo_client = MongoClient.instance
    @processed_payments = mongo_client.db("challenge").collection("processed_payments")
    
    @successful_batches = [] of Hash(String, PaymentProcessorRequest | String)
    @last_insert = Time.utc

    amqp_url = ENV["AMQP_URL"]?.not_nil! # PubSubClient expects a string
    @pubsub_client = PubSubClient.new(amqp_url)
    
    start_batch_timer
  end

  def start_batch_timer
    spawn do
      loop do
        sleep 0.125.seconds # 125ms
        trigger_process
      end
    end
  end

  def add_successful_payment(payment : PaymentProcessorRequest, processor : String)
    @successful_batches << {
      "payment" => payment,
      "processor" => processor
    }
  end

  def trigger_process
    return if @successful_batches.empty?

    puts "Starting Insert Batch"
    to_insert = @successful_batches.dup
    @successful_batches.clear
    @last_insert = Time.utc

    bson_docs = to_insert.map do |entry|
      BSON.new({
        "correlationId" => entry["payment"].as(PaymentProcessorRequest).correlationId,
        "amount" => entry["payment"].as(PaymentProcessorRequest).amount.to_f,
        "processor" => entry["processor"].to_s,
        "timestamp" => entry["payment"].as(PaymentProcessorRequest).requestedAt
      })
    end
    @processed_payments.insert_many(bson_docs)
  end

  def run
    puts "Listening for messages on AMQP queue: #{@pubsub_client.@queue_name}"
    @pubsub_client.subscribe do |delivery|
      begin
        request = PaymentProcessorRequest.from_json(delivery.body_io.to_s)
        request.requestedAt = Time.utc
        response = @circuit_breaker.send_payment(request, ENV["TOKEN"]?)
        add_successful_payment(request, response["processor"].to_s)
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