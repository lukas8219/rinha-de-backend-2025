require "sqlite3"
require "socket"
require "http/client"

class SqliteClient
  @@instance : SqliteClient?
  @@consumer_clients : Array(HTTP::Client)?

  def self.instance
    @@instance ||= new
  end

  @db : DB::Database
  @summary_statement : DB::PoolStatement

  def initialize
    db_path = ENV["SQLITE_PATH"]? || "database.sqlite3"
    @db = DB.open("sqlite3://#{db_path}")
    @db.exec("PRAGMA journal_mode=WAL;")
    @db.exec("PRAGMA cache_size=-5120;")
    @db.exec("CREATE TABLE IF NOT EXISTS consumers (hostname CHAR(255) PRIMARY KEY);")
    @db.exec("CREATE TABLE IF NOT EXISTS processed_payments (id CHAR(36) PRIMARY KEY, timestamp TIMESTAMP, amount INT, processor CHAR(8));")
    sql = <<-SQL
      SELECT processor, COUNT(id) AS totalRequests, COALESCE(SUM(amount), 0) / 100.0 AS totalAmount
      FROM processed_payments
      WHERE timestamp >= ? AND timestamp <= ?
      GROUP BY processor
    SQL
    @summary_statement = @db.build(sql)
    get_consumer_clients
  end

  def insert_consumer(hostname : String)
    @db.exec("INSERT INTO consumers (hostname) VALUES (?)", hostname)
  end

  def query_summary(from_time : String, to_time : String, &block : DB::ResultSet ->)
    @summary_statement.query(from_time, to_time, &block)
  end

  def db
    @db
  end

  def get_consumer_clients
    return @@consumer_clients if @@consumer_clients
    @@consumer_clients ||= begin
      rs = @db.query("SELECT hostname FROM consumers;")
      hosts = [] of HTTP::Client
      rs.each do
        hosts << HTTP::Client.new(UNIXSocket.new(rs.read(String)))
      end
      hosts
    end
  end

  def close
    @db.close
  end
end
