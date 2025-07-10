require "./mongo_client"
require "./circuit_breaker_wrapper"
require "./http_client"
require "./payment_types"

class Consumer
  @circuit_breaker : CircuitBreakerWrapper
  @processed_payments : Cryomongo::Collection
  @batches : Array(Payment)
  @last_insert : Time

  def initialize
    process_client = HttpClient.new(ENV["PROCESSOR_URL"])
    fallback_client = HttpClient.new(ENV["FALLBACK_URL"])
    
    @circuit_breaker = CircuitBreakerWrapper.new(process_client, fallback_client)
    
    mongo_client = MongoClient.instance
    @processed_payments = mongo_client.db("challenge").collection("processed_payments")
    
    @batches = [] of Payment
    @last_insert = Time.utc
    
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

  def insert_processed_payment(payment : Payment)
    if (Time.utc - @last_insert).total_milliseconds > 125
      trigger_process
      return
    end
    @batches << payment
  end

  def trigger_process
    return if @batches.empty?
    
    to_insert = @batches.dup
    @batches.clear
    @last_insert = Time.utc
    
    # Convert payments to BSON format
    bson_docs = to_insert.map(&.to_bson)
    @processed_payments.insert_many(bson_docs)
  end

  def run
    begin
      mongo_client = MongoClient.instance
      db = mongo_client.db("challenge")
      requested_payments = db.collection("requested_payments")

      puts "Listening for changes on requested_payments collection..."

      # Since Crystal's MongoDB driver might not have change streams,
      # we'll use a polling approach as a fallback
      # In a real implementation, you'd want to use proper change streams if available
      last_id = get_last_processed_id
      
      loop do
        sleep 1 # Poll every second
        
        # Get new payments since last processed
        cursor = requested_payments.find({"_id" => {"$gt" => last_id}})
        
        cursor.each do |document|
          begin
            # Extract payment data from document
            payment = Payment.new(
              amount: document["amount"].as(Float64),
              description: document["description"].as(String),
              timestamp: document["timestamp"].as(String)
            )
            
            puts "Processing payment: #{payment.to_json}"
            
            # Send through circuit breaker
            @circuit_breaker.send_payment(payment, ENV["TOKEN"]?)
            
            # Add to processed batch
            insert_processed_payment(payment)
            
            # Update last processed ID
            last_id = document["_id"]
            
          rescue ex
            puts "Error processing payment: #{ex.message}"
          end
        end
      end
      
    rescue ex
      puts "Error running consumer: #{ex.message}"
      exit(1)
    end
  end

  private def get_last_processed_id
    # Try to get the last processed payment ID
    # This is a simplified approach - in practice you'd want to store this state
    cursor = @processed_payments.find({}, sort: {"_id" => -1}, limit: 1)
    doc = cursor.to_a.first?
    doc ? doc["_id"] : nil
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