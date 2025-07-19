require "pg"

class PostgresClient
  @@instance : PostgresClient?

  def self.instance
    @@instance ||= new
  end

  @db : DB::Database
  propertysummary_statement : DB::PoolStatement

  def initialize
    db_url = ENV["POSTGRES_URL"]? || "postgres://postgres:postgres@localhost:5432/rinha"
    @db = DB.open(db_url)
    @db.exec("ALTER SYSTEM SET fsync TO off;")
    @db.exec("ALTER SYSTEM SET wal_level TO minimal;")
    @db.exec("SELECT pg_reload_conf();")
    @db.exec("CREATE UNLOGGED TABLE IF NOT EXISTS processed_payments (id CHAR(36) PRIMARY KEY, timestamp TIMESTAMP, amount BIGINT, processor CHAR(8));")
    @db.exec("CREATE INDEX IF NOT EXISTS idx_processed_payments_processor_ts ON processed_payments(processor, timestamp, amount, id);")
    @summary_statement = @db.build("SELECT processor, COUNT(*) AS totalRequests, (COALESCE(SUM(amount), 0)::NUMERIC / 100)::NUMERIC(10, 2) AS totalAmount FROM processed_payments WHERE timestamp >= $1 AND timestamp <= $2 GROUP BY processor")
  end

  def summary_query(from_time : String, to_time : String, &block : DB::ResultSet ->)
    @summary_statement.query(from_time, to_time, &block)
  end

  def db
    @db
  end

  def close
    @db.close
  end
end

