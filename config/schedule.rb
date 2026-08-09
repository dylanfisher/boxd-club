# In-process cron. One Puma process, no worker, no Redis.
#
# Rounds have no deadlines any more, so nothing here decides anything on a
# clock. These jobs only keep the data fresh and give every club a regular
# chance to move itself along:
#
#   daily_fetch  re-scrape watchlists and club lists, and members' avatars
#   advance      open / tally / check who's logged the winner, per club
#   cleanup      prune expired tokens and rate-limit rows, back up the database
#
# rufus reads process-local time, so TZ must be set in the environment or
# "8am" silently becomes midnight Pacific inside a UTC container.

require "rufus-scheduler"

require_relative "../lib/models"
require_relative "../lib/letterboxd"
require_relative "../lib/avatars"
require_relative "../lib/rounds"
require_relative "../lib/tokens"
require_relative "../lib/throttle"
require_relative "../lib/backup"

module Schedule
  # Cron fires on the dot, and so does everybody else's. Each job waits a
  # random spell before its first request, so our scrape doesn't land on
  # Letterboxd at exactly 08:00:00 alongside every other cron on the internet.
  FETCH_JITTER = 0.0..(45 * 60)
  ADVANCE_JITTER = 0.0..(12 * 60)

  module_function

  # A redeploy restarts the process and re-arms the schedule, which would
  # re-fire jobs that already ran. SQLite serialises writes, so a conditional
  # UPDATE returning a row count is a sufficient lock.
  def claim(name, interval)
    DB[:job_runs]
      .where(name: name)
      .where { last_run_at < Time.now - interval }
      .update(last_run_at: Time.now) == 1
  end

  # An uncaught exception inside a rufus thread dies silently with no trace.
  # Every job body goes through here. Non-negotiable.
  def guard(name)
    yield
  rescue StandardError => e
    warn "[job:#{name}] #{e.class}: #{e.message}\n#{e.backtrace&.first(20)&.join("\n")}"
  end
end

scheduler = Rufus::Scheduler.singleton

scheduler.cron "0 8 * * *" do
  Schedule.guard("daily_fetch") do
    if Schedule.claim("daily_fetch", 20 * 3600)
      Letterboxd.pause(Schedule::FETCH_JITTER)
      # Watchlists only get re-scraped once they're older than
      # Letterboxd::REFRESH_AFTER, so most nights this is a handful of members
      # rather than all of them.
      Letterboxd.refresh_all!(pace: :background)
      # Same site, same pace, and monthly per member — so on most nights this
      # is nothing at all.
      Avatars.refresh_all!(pace: :background)
    end
  end
end

# Every four hours rather than hourly: the only expensive part is asking
# Letterboxd who has logged the winner, which is one request per member who
# hasn't yet. A tally doesn't wait for this — the last ballot submitted decides
# the round on the spot.
scheduler.cron "15 */4 * * *" do
  Schedule.guard("advance") do
    if Schedule.claim("advance", 3.5 * 3600)
      Letterboxd.pause(Schedule::ADVANCE_JITTER)
      Rounds.advance_all!(pace: :background)
    end
  end
end

scheduler.cron "30 3 * * *" do
  Schedule.guard("cleanup") do
    if Schedule.claim("cleanup", 82_800)
      Tokens.cleanup!
      Throttle.cleanup!
      Backup.run!
    end
  end
end

puts "[schedule] armed — TZ=#{ENV.fetch('TZ', '(unset!)')} now=#{Time.now}"
