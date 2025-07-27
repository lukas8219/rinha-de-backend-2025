# Listen to some HTTP Path for Shared-State
# Expose `Channel` in-memory
module PubSub
    class Client
        @channel : Channel(Bytes)
        def initialize()
            @channel = Channel(Bytes).new()
        end

        def publish_payments(message : IO)
            @channel.send(message.getb_to_end)
        end

        def reenqueue_payments(message : Bytes)
            @channel.send(message)
        end

        def subscribe_payments(&block : Bytes -> Nil)
            spawn do
                loop do
                    message = @channel.receive
                    spawn do
                        block.call(message)
                    end
                end
            end
        end
    end
end