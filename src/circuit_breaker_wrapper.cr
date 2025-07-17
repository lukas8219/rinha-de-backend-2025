require "./http_client"
require "./payment_types"

class CircuitBreakerWrapper
  @process_client : HttpClient?
  @fallback_client : HttpClient?

  def initialize(@process_client : HttpClient?, @fallback_client : HttpClient?)
  end

  def get_best_suited_client_and_fallback()
    [
      @process_client.not_nil!,
      @fallback_client.not_nil!
    ].sort_by do |client|
      current_stats = client.current_stats.not_nil!
      current_stats.failing ? 999999999 : current_stats.minResponseTime
    end
  end

  def send_payment(data : PaymentProcessorRequest, token : String?)
    clients = get_best_suited_client_and_fallback()
    clients.each do |client|
      if client.current_stats.not_nil!.failing
        next
      end
      response = client.send_payment(data, token)
      return {
        "processor" => client.name,
        "response" => response.body
      } if response.success?
      if response.status_code == 422
        return {
          "processor" => client.name,
          "response" => data
        }
      end
    end
    return nil
  end

end 