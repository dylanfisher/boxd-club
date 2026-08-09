# What we hold from Letterboxd, gathered for the /cache page.
#
# Nothing here fetches anything — it only reads back what the scrapers in
# lib/letterboxd.rb, lib/films.rb and lib/avatars.rb have already stored. The
# page exists so a member can see the shape and the age of that copy rather
# than guessing why a ballot drew on a film they removed last week.
#
# Everything comes back newest-first, because the only question anyone brings
# to this page is "how out of date is this?".

require_relative "models"
require_relative "letterboxd"
require_relative "films"
require_relative "avatars"

module Cache
  # How many films the page lists. There are thousands in a working database
  # and they're all title-and-year rows until one reaches a ballot, so the tail
  # is not worth the bytes.
  FILM_LIMIT = 100

  # config/schedule.rb seeds job_runs at the epoch and uses it as a lock, so a
  # job that has never run still has a row. Anything older than this is "never".
  NEVER_BEFORE = Time.utc(2000)

  # The scheduled jobs, in the order they matter to somebody reading this page,
  # with what each one actually touches. Cadences mirror the cron lines in
  # config/schedule.rb — change them there and here together.
  JOBS = [
    { name: "daily_fetch", label: "Watchlists, club lists and profile pictures",
      cadence: "daily, around 8am" },
    { name: "advance", label: "Rounds, and who has logged the winner",
      cadence: "every four hours" },
    { name: "cleanup", label: "Expired links, rate limits and the database backup",
      cadence: "daily, around 3:30am" }
  ].freeze

  module_function

  # Members whose cached data this viewer may see: the people they share a club
  # with, plus themselves. An admin sees everyone, as they do everywhere else.
  def visible_users(viewer)
    return User.order(:email).all if viewer.admin

    club_ids = Membership.where(user_id: viewer.id).select(:club_id)
    ids = Membership.where(club_id: club_ids).distinct.select_map(:user_id) | [viewer.id]
    User.where(id: ids).order(:email).all
  end

  # One row per member: how many films we hold for them, and when we last read
  # the list. Members we've never read come last — they have no date to sort by,
  # and they're the ones worth noticing at the bottom.
  def watchlists(viewer)
    users = visible_users(viewer)
    stats = entry_stats(:watchlist_entries, :user_id, users.map(&:id))
    rows = users.map { |user| stat_row(:user, user, stats[user.id]) }
    by_recency(rows)
  end

  # The same, for clubs that draw on one fixed Letterboxd list rather than on
  # watchlists. Clubs in any other mode hold no list, so they aren't here.
  def club_lists(viewer)
    clubs = viewer.admin ? Club.order(:name).all : viewer.clubs_dataset.order(:name).all
    clubs = clubs.select { |c| c.list_mode == "list" }
    stats = entry_stats(:club_list_entries, :club_id, clubs.map(&:id))
    rows = clubs.map { |club| stat_row(:club, club, stats[club.id]) }
    by_recency(rows)
  end

  # How many rows we hold per member (or per club), and when the newest of them
  # was read — in one query for the whole section rather than two per row. The
  # page lists every user in the database for an admin, so the per-row version
  # grew with the user table.
  #
  # SQLite's max() comes back without a column type, which is why
  # User#watchlist_fetched_at reaches for an ORDER BY instead; a grouped query
  # can't, so the timestamp is converted below.
  def entry_stats(table, key, ids)
    return {} if ids.empty?

    DB[table]
      .where(key => ids)
      .group(key)
      .select(key,
              Sequel.function(:count).*.as(:films),
              Sequel.function(:max, :fetched_at).as(:fetched_at))
      .to_hash(key)
  end

  # A member or club with nothing cached has no row in the group-by at all,
  # which is the "never read" case the page calls out.
  def stat_row(label, record, stat)
    { label => record, films: stat ? stat[:films] : 0,
      fetched_at: stat && timestamp(stat[:fetched_at]) }
  end

  # Postgres hands back a Time; SQLite hands back the stored string, because
  # the aggregate above lost the declared type on the way out.
  def timestamp(value)
    return value if value.nil? || value.is_a?(Time)

    DB.to_application_timestamp(value)
  end

  # Films newest-first by when they entered the cache, not by when their details
  # were read: a film is cached the moment it shows up on somebody's watchlist,
  # and details only get filled in for the handful that reach a ballot.
  def films(limit: FILM_LIMIT)
    Film.order(Sequel.desc(:created_at), Sequel.desc(:id)).limit(limit).all
  end

  def film_counts
    { total: Film.count, detailed: Film.exclude(details_fetched_at: nil).count }
  end

  # When each scheduled job last did its work. Never-run jobs sort last.
  def jobs
    runs = DB[:job_runs].to_hash(:name, :last_run_at)
    rows = JOBS.map do |job|
      last = runs[job[:name]]
      job.merge(last_run_at: (last if last && last > NEVER_BEFORE))
    end
    by_recency(rows, key: :last_run_at)
  end

  # How long before each kind of row is read again, so the dates above have
  # something to be judged against.
  def policy
    {
      watchlists: days(Letterboxd::REFRESH_AFTER),
      details: days(Films::REFRESH_AFTER),
      avatars: days(Avatars::REFRESH_AFTER)
    }
  end

  def days(seconds) = (seconds / 86_400.0).round

  # Newest first, with rows we've never fetched at the end rather than jumbled
  # in among the dated ones.
  def by_recency(rows, key: :fetched_at)
    rows.sort_by { |r| [r[key] ? 0 : 1, -(r[key]&.to_f || 0.0)] }
  end
end
