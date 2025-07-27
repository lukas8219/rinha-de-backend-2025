require "amqp-client"

class PubSubClient
  @connection : AMQP::Client::Connection
  @channel : AMQP::Client::Channel
  @health_exchange : AMQP::Client::Exchange
  @worker_exchange : AMQP::Client::Exchange
  @current_shard_index : Atomic(Int32)
  def initialize(url : String)
    @connection = AMQP::Client.new(url).connect
    @channel = @connection.channel
    @queue_name = "processor:queue:#{ENV["SHARDING_KEY"]? || "localhost"}"
    @health_exchange = @channel.fanout_exchange()
    @worker_exchange = @channel.topic_exchange()
    @channel.prefetch(ENV["PREFETCH_COUNT"]? ? ENV["PREFETCH_COUNT"].to_i : 1)
    @current_shard_index = Atomic(Int32).new(0)
  end

  def publish(message : IO)
    shard_key = "#{(@current_shard_index.add(1, :relaxed) % ENV["SHARD_COUNT"]?.not_nil!.to_i) + 1}"
    @worker_exchange.publish(message.getb_to_end, shard_key.to_s)
  end
  
  def publish_health(queue_name : String, message : IO)
    @health_exchange.publish(message.getb_to_end, queue_name)
  end

  def subscribe(&block : AMQP::Client::DeliverMessage -> Nil)
    @channel.queue_declare(@queue_name, durable: false)
    @channel.queue_bind(@queue_name, @worker_exchange.name, ENV["SHARDING_KEY"]?.not_nil!)
    @channel.basic_consume(@queue_name, no_ack: true, work_pool: System.cpu_count) do |delivery|
      block.call(delivery)
    end
  end

  def subscribe_health(queue_name : String, &block : AMQP::Client::DeliverMessage -> Nil)
    @channel.queue_declare(queue_name, durable: false)
    @channel.queue_bind(queue_name, @health_exchange.name, queue_name)
    @channel.basic_consume(queue_name, no_ack: true, work_pool: System.cpu_count) do |delivery|
      block.call(delivery)
    end
  end

  def close
    @channel.close
    @connection.close
  end
end



