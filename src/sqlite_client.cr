require "sqlite3"

class SqliteClient
  @@instance : SqliteClient?

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
    @db.exec("CREATE TABLE IF NOT EXISTS processed_payments (id CHAR(36) PRIMARY KEY, timestamp TIMESTAMP, amount INT, processor CHAR(8));")
    sql = <<-SQL
      SELECT processor, COUNT(id) AS totalRequests, COALESCE(SUM(amount), 0) / 100.0 AS totalAmount
      FROM processed_payments
      WHERE timestamp >= ? AND timestamp <= ?
      GROUP BY processor
    SQL
    @summary_statement = @db.build(sql)
  end

  def query_summary(from_time : String, to_time : String, &block : DB::ResultSet ->)
    @summary_statement.query(from_time, to_time, &block)
  end

  def db
    @db
  end

  def close
    @db.close
  end
end
