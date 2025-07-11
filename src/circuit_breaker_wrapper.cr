require "./forks/circuit_breaker/circuit_breaker"
require "./http_client"
require "./payment_types"

class CircuitBreakerWrapper
  @process_client : HttpClient
  @fallback_client : HttpClient
  @circuit_breaker : CircuitBreaker

  def initialize(@process_client : HttpClient, @fallback_client : HttpClient)
    @circuit_breaker = CircuitBreaker.new(
      threshold: 5, # % of errors before you want to trip the circuit
      timewindow: 60, # in s: anything older will be ignored in error_rate
      reenable_after: 300 # after x seconds, the breaker will allow executions again
    )
  end

  def send_payment(data, token : String?) : Bool
    begin
      @circuit_breaker.run do
        @process_client.send_payment(data, token)
      end
    rescue ex
      @fallback_client.send_payment(data, token)
    end
  end

end 