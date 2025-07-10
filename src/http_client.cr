require "http/client"
require "json"
require "./payment_types"

class HttpClient
  @base_url : String

  def initialize(@base_url : String)
  end

  # Accepts a buffer of data (String or IO) instead of a Payment object
  def send_payment(data, token : String?)
    url = "#{@base_url}/payments"
    
    headers = HTTP::Headers.new
    headers["Content-Type"] = "application/json"
    
    if token
      headers["Authorization"] = "Bearer #{token}"
    end
    puts "Sending payment to #{url}"
    response = HTTP::Client.post(url, headers: headers, body: data)
    if response.success?
      response
    else
      raise "Failed to send payment"
    end
  end
end 