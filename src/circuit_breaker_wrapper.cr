require "./forks/circuit_breaker/circuit_breaker"
require "./http_client"
require "./payment_types"

class CircuitBreakerWrapper
  @process_client : HttpClient?
  @fallback_client : HttpClient?
  @circuit_breaker : CircuitBreaker

  def initialize(@process_client : HttpClient?, @fallback_client : HttpClient?)
    @circuit_breaker = CircuitBreaker.new(
      threshold: ENV["CIRCUIT_BREAKER_THRESHOLD"]?.try(&.to_i) || 5, # % of errors before you want to trip the circuit
      timewindow: ENV["CIRCUIT_BREAKER_TIMEWINDOW"]?.try(&.to_i) || 60, # in s: anything older will be ignored in error_rate
      reenable_after: ENV["CIRCUIT_BREAKER_REENABLE_AFTER"]?.try(&.to_i) || 300 # after x seconds, the breaker will allow executions again
    )
  end

  def send_payment(data, token : String?)
    begin
      @circuit_breaker.run do
        @process_client.not_nil!.send_payment(data, token)
      end
    rescue ex
      @fallback_client.not_nil!.send_payment(data, token)
    end
  end

end 