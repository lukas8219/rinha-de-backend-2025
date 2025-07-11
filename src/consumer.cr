require "./amqp/pubsub-client"
require "json"
require "./mongo_client"
require "./circuit_breaker_wrapper"
require "./http_client"
require "./payment_types"

class Consumer
  @circuit_breaker : CircuitBreakerWrapper
  @processed_payments : Mongo::Collection
  @successful_batches : Array(Payment)
  @last_insert : Time
  @pubsub_client : PubSubClient

  def initialize
    process_client = HttpClient.new(ENV["PROCESSOR_URL"])
    fallback_client = HttpClient.new(ENV["FALLBACK_URL"])
    
    @circuit_breaker = CircuitBreakerWrapper.new(process_client, fallback_client)
    
    mongo_client = MongoClient.instance
    @processed_payments = mongo_client.db("challenge").collection("processed_payments")
    
    @successful_batches = [] of Payment
    @last_insert = Time.utc

    amqp_url = ENV["AMQP_URL"]?.not_nil! # PubSubClient expects a string
    @pubsub_client = PubSubClient.new(amqp_url)
    
    # Start batch processing timer
    start_batch_timer
  end

  def start_batch_timer
    spawn do
      loop do
        sleep 0.125 # 125ms
        trigger_process
      end
    end
  end

  def add_successful_payment(payment : Payment)
    @successful_batches << payment
  end

  def trigger_process
    return if @successful_batches.empty?
    
    to_insert = @successful_batches.dup
    @successful_batches.clear
    @last_insert = Time.utc
    
    # Convert payments to BSON format
    bson_docs = to_insert.map(&.to_bson)
    @processed_payments.insert_many(bson_docs)
    
    puts "Batch inserted #{to_insert.size} successful payments"
  end

  def run
    begin
      queue_name = ENV["QUEUE_NAME"]? || "processor:queue"
      puts "Listening for messages on AMQP queue: #{queue_name}"

      # Use PubSubClient's subscribe method
      @pubsub_client.subscribe do |delivery|
        begin
          puts "Received message: #{delivery.body}"

          payment_data = JSON.parse(delivery.body)
          payment = Payment.new(
            amount: payment_data["amount"].as_f,
            correlationId: payment_data["correlationId"].as_s
          )

          puts "Processing payment: #{payment.to_json}"

          # Send through circuit breaker
          success = @circuit_breaker.send_payment(payment, ENV["TOKEN"]?)

          if success
            puts "Payment processed successfully"
            add_successful_payment(payment)
            # PubSubClient uses no_ack: true, so no manual ack needed
          else
            puts "Payment processing failed"
            # With no_ack: true, cannot requeue, so just log
          end

        rescue ex
          puts "Error processing message: #{ex.message}"
          # With no_ack: true, cannot reject, just log
        end
      end

      # Keep the consumer running
      loop do
        sleep 1
      end

    rescue ex
      puts "Error running consumer: #{ex.message}"
      exit(1)
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