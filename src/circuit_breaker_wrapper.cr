require "circuit_breaker"
require "./http_client"
require "./payment_types"

class CircuitBreakerWrapper
  @process_client : HttpClient
  @fallback_client : HttpClient
  @circuit_breaker : CircuitBreaker::CircuitBreaker
  @response_times : Array(Float64)
  @p75_threshold : Float64

  def initialize(@process_client : HttpClient, @fallback_client : HttpClient, @p75_threshold : Float64 = 100.0)
    @response_times = [] of Float64
    
    # Configure the circuit breaker
    @circuit_breaker = CircuitBreaker::CircuitBreaker.new(
      failure_threshold: 5,
      recovery_timeout: 60,
      expected_exceptions: [Exception]
    )
  end

  def send_payment(payment : Payment, token : String?)
    use_fallback = should_use_fallback?
    client = use_fallback ? @fallback_client : @process_client
    
    start_time = Time.utc
    
    begin
      if use_fallback
        # Direct call to fallback
        result = client.send_payment(payment, token)
        result
      else
        # Use circuit breaker for process client
        result = @circuit_breaker.run do
          client.send_payment(payment, token)
        end
        result
      end
    rescue ex
      puts "Error sending payment: #{ex.message}"
      0
    ensure
      # Record response time for process client only
      if !use_fallback
        duration = (Time.utc - start_time).total_milliseconds
        record_response_time(duration)
      end
    end
  end

  private def should_use_fallback?
    return false if @response_times.size < 10 # Need some data first
    
    # Calculate p75 from recent response times
    sorted_times = @response_times.sort
    p75_index = (sorted_times.size * 0.75).to_i
    p75_value = sorted_times[p75_index]
    
    p75_value > @p75_threshold
  end

  private def record_response_time(duration : Float64)
    @response_times << duration
    
    # Keep only last 100 response times to avoid memory issues
    if @response_times.size > 100
      @response_times.shift
    end
  end

  def set_threshold(threshold : Float64)
    @p75_threshold = threshold
  end
end 