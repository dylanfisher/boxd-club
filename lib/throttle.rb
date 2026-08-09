# Rate limiting for the forms that can put mail in somebody's inbox.
#
# There is no password anywhere — /login mails a sign-in link — so the abuse
# worth stopping isn't credential stuffing, it's someone holding down a form
# that emails a member over and over, or walking a list of addresses through it.
#
# A row per attempt in SQLite, counted over a sliding window. Not Redis, not a
# per-process hash: one Puma process today, but a counter in memory forgets
# everything on every deploy, which is exactly when someone would notice it
# resets. Rows are pruned per bucket on use and swept nightly, so the table
# stays in the low hundreds.
#
# Two buckets guard each form: one on the target (an email address — protects
# the person receiving the mail, wherever the requests come from) and one on
# the client IP (protects everyone else from one source working through a
# list). Both are checked, and the tighter one wins.

require_relative "models"

module Throttle
  # Everything is keyed off these, so a limit is changed in one place and the
  # message the user sees stays in step with it.
  LIMITS = {
    # A member asking for their own sign-in link. Three is enough to cover
    # "it didn't arrive, send another" without becoming a way to fill an inbox.
    login_email: { limit: 3, per: 3600 },
    # One address per attempt, so this is the cap on how many addresses a
    # single source can probe in an hour.
    login_ip: { limit: 10, per: 3600 },
    # Admin-sent invites. Generous — setting a club up is a legitimate burst —
    # but a bounded one, so a borrowed admin session can't mail a list.
    invite_ip: { limit: 30, per: 3600 }
  }.freeze

  module_function

  # Records an attempt and says whether it's allowed. Call once per attempt:
  # asking is what consumes the allowance.
  #
  # The count and the insert share a transaction. SQLite serialises writers, so
  # two simultaneous requests can't both read "2 of 3" and both insert.
  def allow?(name, key)
    rule = LIMITS.fetch(name)
    bucket = "#{name}:#{key}"
    cutoff = Time.now - rule[:per]

    DB.transaction do
      DB[:rate_limits].where(bucket: bucket).where { created_at < cutoff }.delete
      next false if DB[:rate_limits].where(bucket: bucket).count >= rule[:limit]

      DB[:rate_limits].insert(bucket: bucket, created_at: Time.now)
      true
    end
  end

  # How long the window is, in words, for the "try again later" message.
  def window_label(name)
    seconds = LIMITS.fetch(name)[:per]
    return "an hour" if seconds == 3600

    minutes = (seconds / 60.0).round
    minutes == 1 ? "a minute" : "#{minutes} minutes"
  end

  # Anything left over from a bucket nobody has touched since. Windows are an
  # hour at most, so a day-old row is dead weight by definition.
  def cleanup!
    n = DB[:rate_limits].where { created_at < Time.now - 86_400 }.delete
    puts "[cleanup] removed #{n} stale rate-limit rows"
    n
  end
end
