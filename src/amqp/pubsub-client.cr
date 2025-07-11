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

  def publish(message : String)
    @channel.basic_publish(message, "", @queue_name)
  end

  def subscribe(&block)
    @channel.queue_declare(@queue_name, durable: false)
    @channel.basic_consume(@queue_name, no_ack: true, &block)
  end

  def close
    @channel.close
    @connection.close
  end
end



