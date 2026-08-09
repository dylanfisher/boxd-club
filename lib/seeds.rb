# Canned watchlists for the demo club.
#
# The demo used to scrape four real Letterboxd accounts every time it ran,
# which is a couple of thousand films over ~50 requests — slow, and rude to a
# site doing us a favour for something that only needs to be plausible data.
# So the scrape happens once and lands in db/seeds/watchlists/*.csv, and the
# seed reads those.
#
# The files are Letterboxd's own export format (Name, Year, Letterboxd URI), so
# Letterboxd.from_csv reads them and you can drop a real watchlist.csv from
# letterboxd.com/settings/data/ in beside them.
#
#   rake seed_demo          reads the checked-in CSVs
#   rake seed_demo[fetch]   re-scrapes and rewrites them

require "csv"
require "fileutils"

require_relative "letterboxd"
require_relative "votes"

module Seeds
  DIR = File.join(APP_ROOT, "db", "seeds", "watchlists")

  # email => Letterboxd username. demo@ is the only admin in the set: you
  # become them by pasting their sign-in link and no other way, so a fresh
  # private window is always a logged-out stranger rather than a silent
  # administrator.
  PEOPLE = {
    "demo@example.com" => "deathproof",
    "alice@example.invalid" => "schaffrillas",
    "bob@example.invalid" => "sidneyprescott",
    "cara@example.invalid" => "karsten"
  }.freeze

  module_function

  def path(username)
    File.join(DIR, "#{username}.csv")
  end

  def fixture?(username)
    File.exist?(path(username))
  end

  # Entries for one person: the checked-in CSV unless you asked to fetch, or
  # there's no CSV yet.
  def watchlist(username, fetch: false)
    return Letterboxd.watchlist(username) if fetch || !fixture?(username)

    File.open(path(username), "r") { |io| Letterboxd.from_csv(io) }
  end

  # Scrapes every seeded account and writes the CSVs. Failures are per-person:
  # one unreachable watchlist leaves that file as it was rather than losing the
  # whole set.
  def refresh!
    FileUtils.mkdir_p(DIR)

    PEOPLE.each_value do |username|
      entries = Letterboxd.watchlist(username)
      if entries.empty?
        warn "  #{username}: 0 films — empty or private, keeping the existing file"
        next
      end

      write(username, entries)
      puts "  #{username}: #{entries.size} films -> #{path(username).delete_prefix("#{APP_ROOT}/")}"
    rescue Letterboxd::Error, SocketError, SystemCallError => e
      warn "  #{username}: #{e.class}: #{e.message}"
    end
  end

  # Casts a ballot for everyone in the round who still owes one, so an open
  # round can be seen through to a result without opening four private windows
  # and ranking five films in each.
  #
  # `except` holds the people to leave alone — by default the admin you browse
  # as, so the round sits one ballot short and yours is the vote that decides
  # it. That's the interesting state: everything downstream of submitting a
  # ballot (the tally, the result page, the result email) happens on the real
  # path rather than being simulated here.
  #
  # Rankings are random, which is the point — a fixed order would make every
  # tally come out the same and hide ties.
  def vote!(round, except: ["demo@example.com"])
    round.pending_voters.reject { |u| except.include?(u.email) }.map do |user|
      ranking = round.candidates.shuffle.each_with_index.to_h { |c, i| [c.id, i + 1] }
      Votes.record_ranking!(round, user, ranking)
      user
    end
  end

  def write(username, entries)
    FileUtils.mkdir_p(DIR)

    CSV.open(path(username), "w") do |csv|
      csv << ["Name", "Year", "Letterboxd URI"]
      entries.each do |e|
        csv << [e[:title], e[:year], "#{Letterboxd::BASE}/film/#{e[:slug]}/"]
      end
    end
  end
end
