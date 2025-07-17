require "sqlite3"

class SqliteClient
  @@instance : SqliteClient?

  def self.instance
    @@instance ||= new
  end

  @db : DB::Database

  def initialize
    db_path = ENV["SQLITE_PATH"]? || "database.sqlite3"
    @db = DB.open("sqlite3://#{db_path}")
    @db.exec("PRAGMA journal_mode=WAL;")
    @db.exec("CREATE TABLE IF NOT EXISTS processed_payments (id CHAR(36) PRIMARY KEY, timestamp TIMESTAMP, amount INT, processor CHAR(8));")
  end

  def db
    @db
  end

  def close
    @db.close
  end
end
