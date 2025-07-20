require "./amqp/pubsub-client"
require "json"
require "./circuit_breaker_wrapper"
require "./http_client"
require "./payment_types"
require "./sqlite_client"
require "./lib/lock-free-deque"
require "kemal"

Log.setup_from_env

class Consumer
  @circuit_breaker : CircuitBreakerWrapper
  @processed_payments : DB::Database
  @successful_batches : LockFreeDeque(Hash(String, PaymentProcessorRequest | String))
  @pubsub_client : PubSubClient
  @atomic_index : Atomic(Int32)
  @last_insert_offset : Atomic(Int32)
  @last_insert_time : Atomic(Int64)
  @insert_channel : Channel(Hash(String, PaymentProcessorRequest | String))
  @delay : Time::Span
  property inserted_records : Atomic(Int32)

  def initialize
    amqp_url = ENV["AMQP_URL"]? || "amqp://guest:guest@localhost:5672/"
    @pubsub_client = PubSubClient.new(amqp_url)
    process_client = HttpClient.new("default", @pubsub_client, ENV["PROCESSOR_URL"]? || "http://localhost:8001", 2000)
    fallback_client = HttpClient.new("fallback", @pubsub_client, ENV["FALLBACK_URL"]? || "http://localhost:8002", 5000)
    @atomic_index = Atomic(Int32).new(0)
    @last_insert_offset = Atomic(Int32).new(0)
    @circuit_breaker = CircuitBreakerWrapper.new(process_client, fallback_client)
    @last_insert_time = Atomic(Int64).new(Time.utc.to_unix_ms)
    @insert_channel = Channel(Hash(String, PaymentProcessorRequest | String)).new
    @delay = ENV["BATCH_INTERVAL"]? ? ENV["BATCH_INTERVAL"].to_f.milliseconds : 125.milliseconds
    @inserted_records = Atomic(Int32).new(0)

    @processed_payments = SqliteClient.instance.db
    
    @successful_batches = LockFreeDeque(Hash(String, PaymentProcessorRequest | String)).new(1000000)
    if ENV["USE_CHANNEL"]?
      rcv_loop
    else
      start_batch_timer
    end
  end
  
  def rcv_loop
    spawn do
      loop do
        entry = @insert_channel.receive
        @processed_payments.exec(
          "INSERT INTO processed_payments (external_id, timestamp, amount, processor) VALUES (?, ?, ?, ?)",
          entry["entry"].as(PaymentProcessorRequest).correlationId,
          entry["entry"].as(PaymentProcessorRequest).requestedAt.not_nil!,
          (entry["entry"].as(PaymentProcessorRequest).amount * 100).round.to_i64,
          entry["processor"].to_s
        )
      end
    end
  end

  def start_batch_timer
    Log.info { "Starting 10 runners out of #{System.cpu_count} CPU" }
    10.times do
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
      now = Time.utc.to_unix_ms
      last_insert = @last_insert_time.get
      elapsed = now - last_insert

      if elapsed >= @delay.to_i
        trigger_process
        # After processing, update last_insert_time inside trigger_process
        sleep 0.01.nanoseconds # short sleep to avoid busy loop
      else
        sleep_time = @delay.to_i - elapsed
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
    to_insert = [] of Hash(String, PaymentProcessorRequest | String)
    batch_records = LockFreeDeque(Hash(String, PaymentProcessorRequest | String)).new(1000000)
    init_ts = Time.utc.to_unix_ms
    while !@successful_batches.empty?
      Log.info { "Getting next payment from batch" }
      next_payment = @successful_batches.shift?
      if next_payment
        Log.info { "Inserting payment into batch" }
        batch_records << next_payment
      else
        break
      end
    end

    if batch_records.empty?
      return
    end

    # Batch insert with a single INSERT statement and multiple VALUES
    unless batch_records.empty?
      @processed_payments.transaction do |tx|
        while !batch_records.empty?
          entry = batch_records.shift?
          if entry
            @processed_payments.exec(
              "INSERT INTO processed_payments (id, timestamp, amount, processor) VALUES (?, ?, ?, ?)",
              entry["entry"].as(PaymentProcessorRequest).correlationId,
              entry["entry"].as(PaymentProcessorRequest).requestedAt.not_nil!,  
              (entry["entry"].as(PaymentProcessorRequest).amount * 100).round.to_i64,
              entry["processor"].to_s
            )
          end
        end
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
        add_successful_payment(request, response["processor"].to_s) if response
        if response.nil?
          @pubsub_client.publish(delivery.body_io)
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
  SqliteClient.instance.close
  exit(0)
end
consumer = Consumer.new

hostname = ENV["HOSTNAME"]? || "consumer"
socket_sub_folder = ENV.fetch("SOCKET_SUB_FOLDER", "/dev/shm")
socket_path = "#{socket_sub_folder}/#{hostname}.sock"
SqliteClient.instance.insert_consumer(socket_path)

# Remove the socket file if it already exists to avoid bind errors
if File.exists?(socket_path)
  File.delete(socket_path)
end

# Simple health check endpoint
get "/stats" do |env|
  env.response.content_type = "application/json"
  { "inserted_records" => consumer.inserted_records.get }.to_json
end

# Start Kemal server bound to the UNIX socket
spawn do
  Log.info { "Starting Kemal server" }
  Kemal.run do |config|
    config.server.not_nil!.bind_unix(socket_path)
    File.chmod(socket_path, 0o666)
  end
end
# Start the consumer
consumer.run 
loop do
  sleep 1.seconds
end


# Determine the UNIX socket path using the HOSTNAME environment variable
