require "http/client"
require "json"
require "./payment_types"

class HttpClient
  @base_url : String

  def initialize(@base_url : String)
  end

  def send_payment(payment : Payment, token : String?) : Int32
    url = "#{@base_url}/payments"
    
    headers = HTTP::Headers.new
    headers["Content-Type"] = "application/json"
    
    if token
      headers["Authorization"] = "Bearer #{token}"
    end

    begin
      response = HTTP::Client.post(url, headers: headers, body: payment.to_json)
      
      if response.success?
        1
      else
        0
      end
    rescue ex
      puts "HTTP request failed: #{ex.message}"
      0
    end
  end
end 