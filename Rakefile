require_relative "config/boot"

MIGRATIONS_DIR = File.join(APP_ROOT, "db", "migrate")

def find_club(slug)
  club = slug ? Club.first(slug: slug) : Club.first
  abort "no such club: #{slug}. Try: rake clubs" if club.nil?
  club
end

namespace :db do
  desc "Run pending migrations"
  task :migrate, [:version] do |_t, args|
    Sequel.extension :migration
    opts = args[:version] ? { target: Integer(args[:version]) } : {}
    Sequel::Migrator.run(DB, MIGRATIONS_DIR, **opts)
    puts "migrated to #{DB[:schema_info].first[:version]}"
  end

  desc "The deploy hook: snapshot, then migrate, only if anything is pending"
  task :release do
    Sequel.extension :migration
    if Sequel::Migrator.is_current?(DB, MIGRATIONS_DIR)
      puts "schema is current — nothing to migrate"
      next
    end

    # This runs before the new container is scheduled, with the old one still
    # serving, so the snapshot is of a database nobody has migrated yet — the
    # thing you'd want back if a migration is wrong in a way SQLite accepts.
    require_relative "lib/backup"
    Backup.run!(label: "pre-migrate")

    Sequel::Migrator.run(DB, MIGRATIONS_DIR)
    puts "migrated to #{DB[:schema_info].first[:version]}"
  end

  desc "Show migration status"
  task :status do
    Sequel.extension :migration
    current = DB.table_exists?(:schema_info) ? DB[:schema_info].first[:version] : 0
    latest = Dir[File.join(MIGRATIONS_DIR, "*.rb")].size
    puts "current: #{current}  latest: #{latest}"
    puts(Sequel::Migrator.is_current?(DB, MIGRATIONS_DIR) ? "up to date" : "PENDING MIGRATIONS")
  end
end

desc "List clubs"
task :clubs do
  require_relative "lib/models"
  abort "no clubs yet — try: rake club[\"Name\"]" if Club.count.zero?
  Club.order(:name).each do |c|
    round = c.current_round
    puts format("%-20s %-14s %2d members  %s", c.slug, c.list_mode, c.members.size,
                round ? "#{round.label.downcase} #{round.state}" : "nothing open")
  end
end

desc "Create a club: rake club[\"Thursday Club\",own]"
task :club, %i[name mode list_url] do |_t, args|
  require_relative "lib/clubs"
  name = args[:name] or abort "usage: rake club[\"Name\",mode,list_url]"
  club = Clubs.create!(name: name, list_mode: args[:mode] || "own", list_url: args[:list_url])
  puts "created #{club.slug} (#{club.list_mode})"
end

desc "Add an existing user to a club: rake join[slug,email]"
task :join, %i[slug email] do |_t, args|
  require_relative "lib/clubs"
  club = find_club(args[:slug])
  user = User.first(email: args[:email].to_s.downcase) or abort "no user #{args[:email]}"
  Clubs.add_member!(club, user)
  puts "#{user.email} joined #{club.name}"
end

desc "Invite someone: rake invite[email,club_slug]"
task :invite, %i[email slug] do |_t, args|
  require_relative "lib/invites"
  email = args[:email] or abort "usage: rake invite[someone@example.com,club-slug]"
  club = args[:slug] ? find_club(args[:slug]) : nil
  Invites.send!(email, club: club)
end

desc "Print a sign-in link for an existing user: rake link[email,/club/demo]"
task :link, %i[email to] do |_t, args|
  require_relative "lib/tokens"
  email = args[:email] or abort "usage: rake link[someone@example.com,/club/demo]"
  user = User.first(email: email.to_s.downcase) or abort "no user #{email}"
  # Mints the same token the email would carry — the point is to become another
  # member locally without digging a link out of the mail log.
  puts Tokens.login_url(user, args[:to] || "/")
end

desc "Make someone an admin: rake admin[email]"
task :admin, [:email] do |_t, args|
  require_relative "lib/invites"
  email = args[:email] or abort "usage: rake admin[you@example.com]"
  Invites.send!(email, admin: true)
end

desc "Fetch one watchlist from Letterboxd and print it"
task :fetch, [:username] do |_t, args|
  require_relative "lib/letterboxd"
  username = args[:username] or abort "usage: rake fetch[username]"
  entries = Letterboxd.watchlist(username) { |page, total| print "\rpage #{page} (#{total} films)" }
  puts "\n#{entries.size} films"
  entries.first(5).each { |e| puts "  #{e[:slug]}  #{e[:title]} (#{e[:year]})" }
end

desc "Re-scrape every member's watchlist and every club list, ignoring freshness"
task :refresh do
  require_relative "lib/letterboxd"
  # You asked for it by hand, so it doesn't skip fresh data and doesn't sit
  # through the nightly job's minutes-long staggers.
  Letterboxd.refresh_all!(pace: :interactive, force: true)
end

desc "Re-read what a list club's members have watched lately, and say what it rules out: rake seen[slug]"
task :seen, %i[slug] do |_t, args|
  require_relative "lib/letterboxd"
  club = find_club(args[:slug])
  abort "#{club.slug} is in #{club.list_mode} mode — only list clubs need this" unless club.list_mode == "list"

  users = club.linked_members
  abort "no members with a Letterboxd account in #{club.slug}" if users.empty?
  list_size = DB[:club_list_entries].where(club_id: club.id).count
  abort "no list cached for #{club.slug} — try: rake refresh" if list_size.zero?

  # Two requests each — the feed and the films page — at the interactive pace:
  # you asked for it by hand, so it doesn't sit through the nightly job's
  # staggers.
  users.each do |u|
    Letterboxd.refresh_watched!(u)
    Letterboxd.pause(Letterboxd::PACE.fetch(:interactive))
  end

  users.each do |u|
    puts format("  %-20s %5d watched films on file", u.letterboxd_username, Seen.user_count(u.id))
  end
  puts "\n#{list_size} films on the list, " \
       "#{Seen.watched_on_list_count(club, users.map(&:id))} of them already watched by somebody"
  puts "The feed only reaches back ~50 entries — for the rest, rake import_watched[email,watched.csv]"
end

desc "Import a Letterboxd watched.csv for someone: rake import_watched[email,path] (asks first; CONFIRM=seen skips the prompt)"
task :import_watched, %i[email path] do |_t, args|
  require_relative "lib/letterboxd"
  user = User.first(email: args[:email].to_s.downcase) or abort "usage: rake import_watched[you@example.com,watched.csv]"
  path = args[:path] or abort "usage: rake import_watched[#{user.email},watched.csv]"

  # watched.csv and watchlist.csv have identical columns, so nothing about the
  # file itself says which is which — and the wrong one marks every film this
  # person *wants* to see as already seen, which nothing in the UI undoes.
  # The web upload catches it by filename; here the name is checked too (it
  # wasn't being passed through at all, so the guard never fired on this path),
  # and on top of that you have to say out loud that you know what you're doing.
  puts "About to mark every film in #{File.basename(path)} as already watched by #{user.email}."
  puts "This must be watched.csv — films they have SEEN — not watchlist.csv, which is films"
  puts "they want to see. Importing the wrong one can't be undone from the site."
  print "Type 'seen' to go ahead: "
  answer = ($stdin.tty? ? $stdin.gets : ENV.fetch("CONFIRM", nil)).to_s.strip
  abort "Nothing imported." unless answer == "seen"

  result = File.open(path, "r") do |io|
    Letterboxd.import_watched!(user, io, filename: File.basename(path))
  end
  puts "#{user.email}: read #{result[:read]} films (#{result[:on_file]} watched films on file)"
rescue Letterboxd::BadImport => e
  abort e.message
end

desc "Fetch everyone's Letterboxd profile picture"
task :avatars do
  require_relative "lib/avatars"
  # By hand means you want it now, so this ignores the monthly freshness check
  # and doesn't sit through the nightly job's staggers.
  n = Avatars.refresh_all!(pace: :interactive, force: true)
  puts "checked #{n} #{n == 1 ? 'member' : 'members'}"
  User.exclude(letterboxd_username: nil).order(:email).each do |u|
    puts format("  %-20s %s", u.letterboxd_username, u.avatar_src || "(no picture)")
  end
end

desc "Move every club along: open, tally, or check who's logged the winner"
task :advance do
  require_relative "lib/rounds"
  Rounds.advance_all!
end

desc "Print the ballot a club would get, without opening a round"
task :dry_run, [:slug] do |_t, args|
  require_relative "lib/rounds"
  Rounds.dry_run!(find_club(args[:slug]))
end

desc "Fill in director, rating and poster for films that are missing them"
task :enrich, [:limit] do |_t, args|
  require_relative "lib/films"
  limit = (args[:limit] || 25).to_i
  films = Film.where(details_fetched_at: nil).limit(limit).all
  puts "enriching #{films.size} films#{TMDB.configured? ? '' : ' (no TMDB_API_KEY — Letterboxd posters)'}"
  Films.enrich_all!(films)
  films.each { |f| puts "  #{Film[f.id].display}" }
end

desc "List everyone and their watchlist freshness"
task :people do
  require_relative "lib/models"
  rows = User.order(:email).all
  abort "no users yet — try: rake invite[you@example.com]" if rows.empty?
  rows.each do |u|
    last = u.watchlist_fetched_at
    age = last ? "#{((Time.now - last) / 86_400).floor}d ago" : "never"
    state = if u.unsubscribed_at then "unsubscribed"
            elsif u.verified_at then "active"
            else "invited"
            end
    puts format("%-32s %-13s %-18s %4d films  fetched %-8s %s",
                u.email, state, u.letterboxd_username || "-", u.watchlist_size, age,
                u.clubs.map(&:slug).join(","))
  end
end

desc "A demo club with four real public watchlists, for local tuning: rake seed_demo[fetch]"
task :seed_demo, [:fetch] do |_t, args|
  require_relative "lib/seeds"
  require_relative "lib/clubs"
  require_relative "lib/tokens"

  # Off the checked-in CSVs by default — no network, and a couple of seconds
  # rather than a couple of minutes. `rake seed_demo[fetch]` goes to Letterboxd
  # instead, without rewriting the fixtures; `rake seed_fixtures` does that.
  fetch = args[:fetch].to_s == "fetch"
  puts fetch ? "fetching watchlists from Letterboxd" : "using #{Seeds::DIR.delete_prefix("#{APP_ROOT}/")} (pass [fetch] to re-scrape)"

  club = Club.first(slug: "demo") || Clubs.create!(name: "Demo")
  club.update(slug: "demo")

  seeded = {}

  Seeds::PEOPLE.each do |email, lb|
    user = User.first(email: email) || User.create(email: email)
    # The seed is authoritative about admin for its own fixtures: demo@ is the
    # admin you browse as, the other three are plain members and stay that way.
    # Re-running the seed is how you undo a stray `rake admin[alice@…]` — an
    # admin link showing up while you're testing as a member defeats the point.
    #
    # onboarded_at goes back to nil for the same reason: the members' panel is
    # part of what you're here to look at, and migration 005 backfilled it (or
    # you dismissed it last time), so without this the seed quietly loses it.
    user.update(letterboxd_username: lb, active: true, verified_at: user.verified_at || Time.now,
                admin: email == "demo@example.com", onboarded_at: nil)
    Clubs.add_member!(club, user)
    seeded[user] = lb

    # One unreachable watchlist shouldn't cost you the whole seed — the club
    # still works on the members that did load.
    begin
      count = Letterboxd.store!(user, Seeds.watchlist(lb, fetch: fetch))
      puts "#{email} (#{lb}): #{count} films"
    rescue Letterboxd::Error, SocketError, SystemCallError => e
      puts "#{email} (#{lb}): no watchlist — #{e.class}: #{e.message}"
    end
  end

  # Nothing signs you in on its own: these are the way in. Paste one into a
  # private window and you are that person until you close it, which is what
  # makes "what does a plain member see?" answerable. Real login tokens, so
  # this is the actual auth path rather than a testing back door — they last
  # 60 days, and `rake link[email]` mints a fresh one whenever you need it.
  puts "\nSign-in links — paste one per private window:\n\n"
  seeded.each do |user, lb|
    role = user.admin ? "admin" : "member"
    label = user.email.split("@").first
    puts format("  %-22s %-8s %s", lb, "(#{role})", Tokens.dev_login_url(user, club.path, label))
  end
  puts "\nnow try: rake dry_run[demo]"
end

desc "Vote for everyone but you, so a round is one ballot from a result: rake demo_vote[demo,all]"
task :demo_vote, %i[slug who] do |_t, args|
  require_relative "lib/seeds"
  require_relative "lib/rounds"
  require_relative "lib/tokens"

  club = find_club(args[:slug] || "demo")
  round = club.current_round || Rounds.open!(club)
  abort "couldn't open a round for #{club.slug} — try: rake dry_run[#{club.slug}]" if round.nil?
  unless round.open?
    abort "#{round.label.downcase} is #{round.state} (#{Film[round.winning_film_id]&.display}). " \
          "Close it from the admin page — 'mark watched' opens the next one."
  end

  # `all` includes the admin, for when you want a finished round to look at
  # rather than a ballot to cast.
  except = args[:who].to_s == "all" ? [] : ["demo@example.com"]
  voted = Seeds.vote!(round, except: except)

  puts "#{round.label.downcase}: #{voted.size} ballot#{voted.size == 1 ? '' : 's'} cast"
  voted.each { |u| puts "  #{u.email}" }

  # Same decision the last ballot would trigger, but tallied inline: the route
  # mails the results on a background thread, which a rake process would exit
  # out from under.
  Rounds.tally!(round) if Rounds.everyone_voted?(round)

  round.refresh
  if round.decided?
    puts "\ndecided: #{Film[round.winning_film_id].display}"
    Votes.standings(round).each_with_index do |s, i|
      puts format("  %d. %-50.50s %2d pts  %d first%s", i + 1, s[:film].display,
                  s[:points], s[:firsts], s[:firsts] == 1 ? "" : "s")
    end
  else
    waiting = round.pending_voters
    puts "\nwaiting on #{waiting.map(&:email).join(', ')} — rank the ballot as them to decide it"
    next unless APP_ENV == "development"

    waiting.each do |u|
      puts "  #{Tokens.dev_login_url(u, club.path, u.email.split('@').first)}"
    end
  end
end

desc "Close the current round without waiting on Letterboxd logs, opening the next: rake demo_next[demo]"
task :demo_next, [:slug] do |_t, args|
  require_relative "lib/rounds"

  club = find_club(args[:slug] || "demo")
  round = club.current_round or abort "no open round in #{club.slug} — try: rake demo_vote[#{club.slug}]"

  # A decided round normally waits for every member to log the film on
  # Letterboxd, which you can't fake for accounts you don't own. This is the
  # admin page's 'mark watched' button: it closes the round and opens the next.
  Rounds.force_tally!(round) if round.open?
  Rounds.mark_watched!(round.refresh)
  puts club.open_round ? "#{club.open_round.label.downcase} is open" : "no new round — try: rake dry_run[#{club.slug}]"
end

desc "Re-scrape the demo watchlists and rewrite db/seeds/watchlists/*.csv"
task :seed_fixtures do
  require_relative "lib/seeds"
  puts "scraping #{Seeds::PEOPLE.size} watchlists — this takes a minute"
  Seeds.refresh!
end

desc "Run the tests"
task :test do
  # A subprocess, so the suite gets its own environment: test/helper.rb sets
  # DATABASE_URL and friends before config/boot.rb connects, and this file has
  # already connected to the development database by the time it's loaded.
  sh "ruby", "test/all.rb"
end
