# Loaded by everything: the web app, the Rakefile, and the scheduler.
# Connects the database and configures outbound mail. Nothing else.

require "sequel"
require "logger"

ENV["RACK_ENV"] ||= "development"
APP_ENV = ENV["RACK_ENV"]
APP_ROOT = File.expand_path("..", __dir__)

# BASE_URL is used to build magic links in emails, so it must be absolute and
# must not have a trailing slash.
BASE_URL = ENV.fetch("BASE_URL", "http://localhost:9292").sub(%r{/+\z}, "")

Sequel.default_timezone = :utc

# All four PRAGMAs are per-connection. Without them, concurrent access from the
# scheduler thread and the web threads raises SQLITE_BUSY.
DB = Sequel.connect(
  ENV.fetch("DATABASE_URL", "sqlite://#{File.join(APP_ROOT, 'db', 'boxd.db')}"),
  max_connections: 5,
  after_connect: proc do |conn|
    conn.execute("PRAGMA journal_mode = WAL")
    conn.execute("PRAGMA busy_timeout = 5000")
    conn.execute("PRAGMA synchronous = NORMAL")
    conn.execute("PRAGMA foreign_keys = ON")
  end
)

DB.loggers << Logger.new($stdout) if APP_ENV == "development" && ENV["SQL_LOG"]

Sequel::Model.plugin :timestamps, update_on_create: true

# Bootstrap a brand-new database only.
#
# Migrations are otherwise run by hand (`rake db:migrate`), deliberately: a
# release-phase migration that fails wedges every future deploy. But a totally
# empty database is a different case — without this, the very first deploy
# crashloops on "no such table: users" until someone shells in, which looks
# like a broken build rather than a missing step.
#
# This never applies *pending* migrations to an existing schema. If schema_info
# exists, it does nothing at all.
unless DB.table_exists?(:schema_info)
  Sequel.extension :migration
  Sequel::Migrator.run(DB, File.join(APP_ROOT, "db", "migrate"))
  warn "[boot] empty database — created schema at version #{DB[:schema_info].first[:version]}"
end

# Mail is configured lazily — requiring it costs ~8MB and the Rakefile's
# migrate task has no business paying that. Mailer calls this on first send.
#
# The "configured" flag lives on this module rather than in an instance
# variable, so it doesn't reset depending on who the caller happens to be.
module MailConfig
  @configured = false

  def self.configure!
    return if @configured

    require "mail"

    if ENV["SMTP_HOST"].to_s.empty?
      # No credentials: log instead of sending. This is what local development
      # and `rake dry_run` use.
      Mail.defaults { delivery_method :logger }
    else
      host = ENV.fetch("SMTP_HOST")
      port = Integer(ENV.fetch("SMTP_PORT", "587"))
      user = ENV["SMTP_USER"]
      pass = ENV["SMTP_PASS"]

      Mail.defaults do
        delivery_method :smtp,
                        address: host,
                        port: port,
                        user_name: user,
                        password: pass,
                        authentication: (:plain if user),
                        enable_starttls_auto: true,
                        open_timeout: 15,
                        read_timeout: 30
      end
    end

    @configured = true
  end

  # Tests and dry runs opt out of the real transport.
  def self.stub_for_testing!
    require "mail"
    Mail.defaults { delivery_method :test }
    @configured = true
  end
end

def configure_mail! = MailConfig.configure!
