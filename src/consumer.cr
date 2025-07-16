require "./amqp/pubsub-client"
require "json"
require "./circuit_breaker_wrapper"
require "./http_client"
require "./payment_types"
require "./sqlite_client"

class Consumer
  @circuit_breaker : CircuitBreakerWrapper
  @processed_payments : DB::Database
  @successful_batches : Array(Hash(String, PaymentProcessorRequest | String))
  @pubsub_client : PubSubClient
  @atomic_index : Atomic(Int32)
  @last_insert_offset : Atomic(Int32)
  @last_insert_time : Atomic(Int64)

  def initialize
    amqp_url = ENV["AMQP_URL"]? || "amqp://guest:guest@localhost:5672/"
    @pubsub_client = PubSubClient.new(amqp_url)
    process_client = HttpClient.new("default", @pubsub_client, ENV["PROCESSOR_URL"]? || "http://localhost:8001")
    fallback_client = HttpClient.new("fallback", @pubsub_client, ENV["FALLBACK_URL"]? || "http://localhost:8002")
    @atomic_index = Atomic(Int32).new(0)
    @last_insert_offset = Atomic(Int32).new(0)
    @circuit_breaker = CircuitBreakerWrapper.new(process_client, fallback_client)
    @last_insert_time = Atomic(Int64).new(Time.utc.to_unix_ms)

    
    @processed_payments = SqliteClient.instance.db
    
    @successful_batches = [] of Hash(String, PaymentProcessorRequest | String)
    start_batch_timer
  end

  def start_batch_timer
    System.cpu_count.times do
      spawn exec_batch
    end
  end

  def exec_batch
    loop do
      if ENV["SKIP_DELAY"]?
        trigger_process
        sleep 1.nanoseconds
        next
      end
      delay = ENV["BATCH_INTERVAL"]? ? ENV["BATCH_INTERVAL"].to_f.milliseconds : 125.milliseconds
      now = Time.utc.to_unix_ms
      last_insert = @last_insert_time.get
      elapsed = now - last_insert

      if elapsed >= delay.to_i
        trigger_process
        # After processing, update last_insert_time inside trigger_process
        sleep 0.01.nanoseconds # short sleep to avoid busy loop
      else
        sleep_time = delay.to_i - elapsed
        sleep sleep_time > 0 ? sleep_time.nanoseconds : 0.01.nanoseconds
      end
    end
  end

  def add_successful_payment(payment : PaymentProcessorRequest, processor : String)
    if ENV["SKIP_BATCH"]?
      @processed_payments.exec("INSERT INTO processed_payments (id, timestamp, amount, processor) VALUES (?, ?, ?, ?)", payment.correlationId, payment.requestedAt, payment.amount, processor)
    else
      @atomic_index.add(1, :relaxed)
      @successful_batches << to_database_entry(payment, processor)
    end
  end

  def to_database_entry(payment : PaymentProcessorRequest, processor : String)
    {
      "entry" => payment,
      "processor" => processor
    }
  end

  def trigger_process
    return if @successful_batches.empty?
    start_offset = @last_insert_offset.get
    end_offset = @atomic_index.get
    if start_offset == end_offset
      return
    end
    @last_insert_offset.max(end_offset)

    to_insert : Array(Hash(String, PaymentProcessorRequest | String)) = @successful_batches[start_offset...end_offset].as(Array(Hash(String, PaymentProcessorRequest | String)))
    last_insert = Time.utc.to_unix_ms

    # Batch insert with a single INSERT statement and multiple VALUES
    
    unless to_insert.empty?
      @last_insert_time.max(last_insert)
      @processed_payments.transaction do |tx|
        to_insert.each do |entry|
          @processed_payments.exec(
            "INSERT INTO processed_payments (id, timestamp, amount, processor) VALUES (?, ?, ?, ?)",
            entry["entry"].as(PaymentProcessorRequest).correlationId,
            entry["entry"].as(PaymentProcessorRequest).requestedAt.not_nil!,
            entry["entry"].as(PaymentProcessorRequest).amount,
            entry["processor"].to_s
          )
        end
      end
    end
  end

  def run
    puts "Listening for messages on AMQP queue: #{@pubsub_client.@queue_name}"
    @pubsub_client.subscribe do |delivery|
      begin
        request = PaymentProcessorRequest.from_json(delivery.body_io.to_s)
        request.requestedAt = Time.utc.to_s("%Y-%m-%dT%H:%M:%S.%LZ")
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