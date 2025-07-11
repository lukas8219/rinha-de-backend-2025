require "cryomongo"

class MongoClient
  @@instance : MongoClient?

  def self.instance
    @@instance ||= new
  end

  @client : Mongo::Client

  def initialize
    mongo_uri = ENV["MONGO_URI"]? || "mongodb://localhost:27017"
    @client = Mongo::Client.new(mongo_uri)
  end

  def db(name : String)
    @client[name]
  end

  def close
    @client.close
  end
end 