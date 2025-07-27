require "http/client"
require "json"
require "./payment_types"
require "db"

class HttpClientStats
  include JSON::Serializable
  property failing : Bool
  property minResponseTime : Int32

  def initialize(@failing : Bool, @minResponseTime : Int32)
  end
end

class HttpClient
  @base_url : String?
  @stats_client : HTTP::Client
  property name : String
  property current_stats : HttpClientStats?
  property timeout : Int32

  def initialize(@name : String, @pubsub_client : PubSub::Client, @base_url : String?, timeout : Int32 = 500)
    @current_stats = HttpClientStats.new(failing: false, minResponseTime: 0)
    base_uri = URI.parse(@base_url.not_nil!)
    @stats_client = HTTP::Client.new(uri: base_uri)
    @stats_client.read_timeout = 500.milliseconds
    @stats_client.connect_timeout = 500.milliseconds
    @timeout = timeout
    spawn update_health_loop
    # @pubsub_client.subscribe_health(@name) do |delivery|
    #   @current_stats = HttpClientStats.from_json(delivery.body_io.to_s)
    #   # Worth parsing it and checking the `latency` metric. Give it some marging and set as timeout?
    # end
  end

  def update_health_loop()
    loop do
      begin
        update_health
      rescue ex
      end
      sleep 250.milliseconds
    end
  end

  def send_health_update(stats : HttpClientStats)
    #@pubsub_client.publish_health(@name, stats)
  end

  # Accepts a buffer of data (String or IO) instead of a Payment object
  def send_payment(data : PaymentProcessorRequest, token : String?)
    url = "/payments"
    
    headers = HTTP::Headers.new
    headers["Content-Type"] = "application/json"
    
    if token
      headers["Authorization"] = "Bearer #{token}"
    end
    client = HTTP::Client.new(uri: URI.parse(@base_url.not_nil!))
    client.post(url, headers: headers, body: data.to_json)
  end

  def update_health()
    url = "/payments/service-health"
    response = @stats_client.get(url)
    if response.success?
      stats = HttpClientStats.from_json(response.body)
      send_health_update(stats)
      return 0
    end
    return 1
  end
end 