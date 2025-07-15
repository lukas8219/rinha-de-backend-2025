require "amqp-client"

class PubSubClient
  @connection : AMQP::Client::Connection
  @channel : AMQP::Client::Channel

  def initialize(url : String)
    @connection = AMQP::Client.new(url).connect
    @channel = @connection.channel
    @queue_name = "processor:queue"
    @channel.queue_declare(@queue_name, durable: false)
  end

  def publish(message : IO)
    @channel.basic_publish(message.getb_to_end, "", @queue_name)
  end

  def subscribe(&block : AMQP::Client::DeliverMessage -> Nil)
    @channel.queue_declare(@queue_name, durable: false)
    @channel.basic_consume(@queue_name, no_ack: true, work_pool: System.cpu_count) do |delivery|
      block.call(delivery)
    end
  end

  def close
    @channel.close
    @connection.close
  end
end



