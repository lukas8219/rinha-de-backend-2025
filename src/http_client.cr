require "http/client"
require "json"
require "./payment_types"

class HttpClient
  @base_url : String?

  def initialize(@base_url : String?)
  end

  # Accepts a buffer of data (String or IO) instead of a Payment object
  def send_payment(data, token : String?)
    url = "#{@base_url.not_nil!}/payments"
    
    headers = HTTP::Headers.new
    headers["Content-Type"] = "application/json"
    
    if token
      headers["Authorization"] = "Bearer #{token}"
    end
    HTTP::Client.post(url, headers: headers, body: data)
  end
end 