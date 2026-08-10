# Reads public Letterboxd pages.
#
# Letterboxd's API is request-only and they decline personal projects, so this
# reads the public pages instead:
#
#   watchlist(user)        /{user}/watchlist/page/{n}/     — films they want
#   list(owner, slug)      /{owner}/list/{slug}/page/{n}/  — a curated list
#   film_details(slug)     /film/{slug}/                   — director, rating, TMDB id
#   avatar(user)           /{user}/watchlist/page/1/       — their profile picture
#   logged?(user, slug)    /{user}/film/{slug}/            — have they watched it?
#   from_csv(io)           watchlist.csv from an account export
#
# Note which page `avatar` reads: the obvious one, /{user}/, is behind a
# Cloudflare challenge and returns 403 to us (checked 2026-08-08), while the
# watchlist page is not — and it carries the same avatar in its header.
#
# The listing markup carries everything we need inline (verified 2026-08-08):
#
#   <div class="react-component" data-component-class="LazyPoster"
#        data-item-slug="operation-mincemeat-2022"
#        data-item-full-display-name="Operation Mincemeat (2021)">
#
# Note the slug's year and the display year can disagree; the display name wins.
#
# logged? relies on /{user}/film/{slug}/ existing only when that member has a
# diary entry, review or rating for the film. Verified 2026-08-08: films merely
# sitting on their watchlist return 404, watched ones return 200.

require "net/http"
require "openssl"
require "uri"
require "csv"
require "json"
require "nokogiri"

require_relative "models"
require_relative "seen"

module Letterboxd
  BASE = "https://letterboxd.com"

  # Letterboxd is a small site doing us a favour; keep the crawl gentle.
  #
  # Two speeds, because these requests aren't all the same kind. Interactive
  # ones happen with somebody watching a page load — checking a username at
  # signup, filling in the five films about to be emailed — so they stay brisk.
  # Measured: 183 films = 8 requests = 3.3s at the interactive pace.
  #
  # Unattended ones have all night, so they wait a random few seconds between
  # pages and a random few minutes between members. Random rather than fixed:
  # a metronome is exactly what a rate limiter is looking for.
  PACE = {
    interactive: 0.35..0.6,
    background: 4.0..15.0
  }.freeze

  # Gap between one member's watchlist and the next in an unattended refresh.
  # Ten members then take an hour or so, which is nothing to a job with 24 of
  # them, and means we're never more than one request in flight.
  MEMBER_STAGGER = 90.0..600.0

  # Watchlists change slowly, and the ballot only calls the data stale after
  # Rounds::STALE_DAYS. Re-scraping everybody every night would be three times
  # the requests for the same ballots.
  REFRESH_AFTER = 3 * 86_400

  # A listing page holds 28 films (100 for lists). Cap the walk so a markup
  # change can never become an unbounded crawl.
  MAX_PAGES = 200

  # Per-film "has this member watched it?" checks a list-mode club may spend in
  # one nightly run. It's the one thing here that costs a request per film per
  # member, so it's capped rather than paced: 40 checks at the background pace
  # is a quarter of an hour of trickle, and clubs stop being warmed at all once
  # they have Seen::RESERVE ballots' worth of verified film in hand.
  SEEN_BUDGET = 40

  # Ceiling on one response body, so a misbehaving page can't exhaust memory.
  MAX_BODY_BYTES = 8 << 20

  # Same, for an uploaded export. A watched.csv is about 70 bytes a film, so
  # this is room for tens of thousands of them.
  MAX_IMPORT_BYTES = 4 << 20

  # What a Letterboxd export zip starts with, so uploading the zip itself —
  # the obvious mistake — gets an answer rather than a parse error.
  ZIP_MAGIC = "PK\x03\x04"

  # The title Cloudflare puts on its challenge interstitial. It can arrive
  # under a 200, not just a 403.
  CHALLENGE_MARKER = "Just a moment"

  USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " \
               "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

  Error = Class.new(StandardError)

  # An upload we can't use. Deliberately not an Error: it's a message for the
  # person who chose the file, not a failed request to Letterboxd, and it must
  # not be swallowed by anything rescuing TRANSPORT_ERRORS.
  BadImport = Class.new(StandardError)

  # Letterboxd served a Cloudflare interstitial. Retrying immediately won't help.
  RateLimited = Class.new(Error)
  NotFound = Class.new(Error)

  # Every way a request to Letterboxd can fail without it being our bug.
  #
  # One list, because it was three hand-written ones and they drifted: two sites
  # rescued SocketError and SystemCallError but not the timeouts, which are
  # RuntimeError descendants and share no ancestor with either — so a Letterboxd
  # that hung, rather than refusing the connection, came back as a 500 on the
  # signup form. Rescue `*TRANSPORT_ERRORS` rather than spelling any of it out
  # again. Order still matters where NotFound or RateLimited mean something
  # specific: rescue those first, since both descend from Error.
  TRANSPORT_ERRORS = [
    Error,                              # ours: an unexpected status, or a challenge page
    SocketError,                        # DNS didn't resolve
    SystemCallError,                    # connection refused, reset, unreachable
    Net::OpenTimeout, Net::ReadTimeout, # connected, then nothing — the slowest failure
    OpenSSL::SSL::SSLError,             # a bad or expired certificate
    EOFError,                           # the connection closed mid-response
    Net::HTTPBadResponse                # what came back wasn't HTTP
  ].freeze

  # "Citizen Kane (1941)" -> ["Citizen Kane", 1941]
  DISPLAY_NAME = /\A(.*)\s+\((\d{4})\)\z/

  # Avatars come off the page at 48px, which is a blur on a retina screen. The
  # size is encoded in the filename (avtr-0-48-0-48-crop.jpg), and asking for a
  # bigger crop of the same upload works — verified at 220 and 1000.
  AVATAR_CROP = /avtr-0-\d+-0-\d+-crop/
  AVATAR_SIZE = 220

  module_function

  # Sleeps for a random spell inside `range`. Every deliberate pause in the
  # codebase goes through here, so LETTERBOXD_NO_DELAY=1 makes a local dry run
  # finish in seconds.
  def pause(range)
    return if ENV["LETTERBOXD_NO_DELAY"] == "1"

    sleep(range.is_a?(Range) ? rand(range) : range)
  end

  # Walks every page of a public watchlist.
  # Yields (page_number, running_total) after each page if a block is given.
  # Returns [{ slug:, title:, year: }, ...]
  def watchlist(username, pace: :interactive, &on_page)
    walk("#{BASE}/#{username}/watchlist", pace: pace, &on_page)
  end

  # Walks a public list. Same shape as watchlist, but list order is meaningful
  # so entries come back in page order.
  def list(owner, slug, pace: :interactive, &on_page)
    walk("#{BASE}/#{owner}/list/#{slug}", pace: pace, &on_page)
  end

  # The 72 films a member watched most recently, newest first.
  #
  # One page and no further: /{user}/films/ answers, but every paginated form of
  # it — /page/2/, /by/date/, /by/name/, /rated/… — is 403 with
  # `cf-mitigated: challenge` (checked 2026-08-09), while watchlist and list
  # pagination stay open. So a full history can't be walked the way a watchlist
  # can. This tops up lib/seen.rb for free; the rest of the history comes from
  # the per-film checks in `warm_seen!` and from an uploaded export.
  def recent_films(username)
    parse_entries(Nokogiri::HTML(get("#{BASE}/#{username}/films/")))
  end

  def walk(base_path, pace: :interactive)
    entries = []
    seen = Set.new

    (1..MAX_PAGES).each do |page|
      found = 0

      parse_entries(Nokogiri::HTML(get("#{base_path}/page/#{page}/"))).each do |entry|
        next if seen.include?(entry[:slug])

        seen << entry[:slug]
        entries << entry
        found += 1
      end

      yield(page, entries.size) if block_given?

      # Walking past the end returns the page shell with no entries, not a 404.
      break if found.zero?

      pause(PACE.fetch(pace))
    end

    entries
  end

  # Films off one listing page, in page order. Watchlists, lists and the films
  # page all carry the same LazyPoster markup.
  def parse_entries(doc)
    doc.css("[data-item-slug]").filter_map do |node|
      slug = node["data-item-slug"].to_s
      next if slug.empty?

      name = node["data-item-full-display-name"] || node["data-item-name"]
      next if name.to_s.strip.empty?

      title, year = parse_display_name(name)
      { slug: slug, title: title, year: year }
    end
  end

  # A member's profile picture, as an absolute URL, or nil if they've never set
  # one (Letterboxd then renders a generic silhouette, which isn't worth
  # copying — we draw our own initial instead).
  #
  # Gravatar URLs come back untouched: those are already a hotlinkable CDN, and
  # lib/avatars.rb keeps them as links rather than downloading them.
  def avatar(username)
    doc = Nokogiri::HTML(get("#{BASE}/#{username}/watchlist/page/1/"))
    src = doc.at_css("a.avatar img")&.[]("src").to_s
    # /static/ is the stock silhouette Letterboxd serves for an account with no
    # picture. Treat that as "no avatar" so we fall back to our own initial.
    return nil if src.empty? || src.include?("/static/")

    src.sub(AVATAR_CROP, "avtr-0-#{AVATAR_SIZE}-0-#{AVATAR_SIZE}-crop")
  end

  # Has this member logged the film — diary entry, review or rating?
  # A film on their watchlist but not watched returns false.
  def logged?(username, film_slug)
    get("#{BASE}/#{username}/film/#{film_slug}/")
    true
  rescue NotFound
    false
  end

  # Director, Letterboxd rating, TMDB id, a poster and the wide backdrop still,
  # scraped from the film page. Every one of these is optional: unreleased films
  # have no rating, the odd film has no TMDB entry, and plenty have no backdrop.
  def film_details(slug)
    body = get("#{BASE}/film/#{slug}/")
    doc = Nokogiri::HTML(body)
    ld = parse_ld_json(doc)

    {
      director: directors(doc, ld),
      rating: ld.dig("aggregateRating", "ratingValue")&.to_f,
      tmdb_id: (body[/themoviedb\.org\/movie\/(\d+)/, 1] || body[/data-tmdb-id="(\d+)"/, 1])&.to_i,
      # Letterboxd's own CDN serves these without a challenge; used as the
      # fallback when TMDB has no key configured (see lib/tmdb.rb).
      poster_url: ld["image"].to_s.empty? ? nil : ld["image"].to_s,
      backdrop_url: backdrop(doc)
    }
  end

  # The 1920px still behind the header on a Letterboxd film page. Films without
  # one simply have no #backdrop element.
  def backdrop(doc)
    node = doc.at_css("#backdrop")
    return nil if node.nil?

    url = node["data-backdrop2x"].to_s
    url = node["data-backdrop"].to_s if url.empty?
    url.empty? ? nil : url
  end

  def directors(doc, ld)
    from_ld = Array(ld["director"]).filter_map { |d| d["name"] if d.is_a?(Hash) }
    names = from_ld.empty? ? doc.css('a[href^="/director/"]').map { |a| a.text.strip } : from_ld
    names.reject(&:empty?).uniq.first(3).join(", ").then { |s| s.empty? ? nil : s }
  end

  def parse_ld_json(doc)
    raw = doc.css('script[type="application/ld+json"]').map(&:text).find { |t| t.include?("aggregateRating") || t.include?("director") }
    return {} if raw.nil?

    # Letterboxd wraps the JSON in CDATA comments.
    JSON.parse(raw.gsub(%r{/\*.*?\*/}m, "").strip)
  rescue JSON::ParserError
    {}
  end

  # Parses watchlist.csv from a Letterboxd account export
  # (letterboxd.com/settings/data/). Columns: Date, Name, Year, Letterboxd URI.
  def from_csv(io)
    entries = []
    seen = Set.new

    CSV.parse(io.respond_to?(:read) ? io.read : io.to_s, headers: true) do |row|
      uri = row["Letterboxd URI"].to_s
      name = row["Name"].to_s.strip
      next if name.empty?

      slug = uri[%r{/film/([^/]+)/?}, 1]
      # Exports occasionally carry a boxd.it short link rather than the film
      # path. Falling back to a title-derived slug keeps the import working, at
      # the cost of not matching a scraped row for the same film.
      slug ||= slugify(name, row["Year"])
      next if seen.include?(slug)

      year = row["Year"].to_s.strip
      seen << slug
      entries << { slug: slug, title: name, year: (Integer(year) if year =~ /\A\d{4}\z/) }
    end

    entries
  end

  # An uploaded watched.csv from letterboxd.com/user/exportdata/ — the only way
  # to get a member's whole history, since Letterboxd challenges every paginated
  # form of /{user}/films/ (see lib/seen.rb). Everything in the file is a film
  # they've watched, so it lands in the seen cache wholesale.
  #
  # `upload` is Rack's multipart hash: { filename:, tempfile:, type: }. A bare
  # IO works too — the rake task passes one — but then `filename:` has to come
  # with it, or the watchlist.csv check below has nothing to look at.
  #
  # Returns { read:, on_file: }: films in the file, and how many watched films
  # that member has on file afterwards. Not one number, because the two differ
  # — a film already on file, or back on their watchlist, is read and not
  # recorded, and "imported 2,600" for a 3,000-film file invites a bug report.
  def import_watched!(user, upload, filename: nil)
    io = upload.is_a?(Hash) ? upload[:tempfile] : upload
    name = (filename || (upload.is_a?(Hash) ? upload[:filename] : "")).to_s
    # Not `nil?`: a file field submitted with nothing chosen reaches us as an
    # empty String rather than a missing param, and that has no #read on it.
    raise BadImport, "Choose a file first." unless io.respond_to?(:read)

    # Read with a length, so a huge file can't be pulled into memory whole —
    # which also means this comes back as binary however the handle was opened.
    # It has to be declared UTF-8 before any title reaches SQLite, or the first
    # accent in the file takes the import down. `scrub` covers a file that has
    # been through a spreadsheet and come out in some other encoding: a mangled
    # character in one title beats refusing the whole history.
    body = io.read(MAX_IMPORT_BYTES).to_s

    # Truncating silently would be the worst of both: the tail of the history
    # missing, the last row cut mid-line, and a cheerful count either way. One
    # byte past the cap is the whole test.
    unless io.read(1).to_s.empty?
      raise BadImport, "That file is larger than #{MAX_IMPORT_BYTES >> 20}MB, which is more films " \
                       "than Letterboxd exports. Upload watched.csv from the export as it came."
    end

    if body.b.start_with?(ZIP_MAGIC)
      raise BadImport, "That's the zip Letterboxd gave you. Unzip it first, then upload the " \
                       "watched.csv inside."
    end

    # A byte-order mark would otherwise become part of the first column's name,
    # and CSV would hand back a file with no "Name" column in it.
    body = body.dup.force_encoding(Encoding::UTF_8).scrub.delete_prefix("﻿")

    # watched.csv and watchlist.csv have identical columns, so the file itself
    # can't say which is which — and importing the wrong one would mark every
    # film somebody *wants* to see as already seen. The name is the only tell
    # there is, so this one mistake gets caught by name.
    if name.downcase.include?("watchlist")
      raise BadImport, "That's watchlist.csv — films you want to see. It's watched.csv " \
                       "(the same export, a different file) that says what you've seen."
    end

    entries = begin
      from_csv(body)
    rescue CSV::MalformedCSVError
      raise BadImport, "That file isn't a CSV we can read. Upload watched.csv from the " \
                       "export without opening it in a spreadsheet first."
    end

    if entries.empty?
      raise BadImport, "No films in that file. Look for watched.csv inside the export zip — " \
                       "it has a Name, Year and Letterboxd URI column."
    end

    store_watched!(user, entries)
    user.update(watched_imported_at: Time.now)
    { read: entries.size, on_file: Seen.user_count(user.id) }
  end

  # Upserts films by slug. Films are shared across users and clubs, so they're
  # never deleted here.
  #
  # One query for the lot rather than one per entry: an imported history runs to
  # thousands of films, and a round-trip each made the import a minutes-long
  # thing to do inside a web request.
  def film_ids_for(entries)
    films = Film.where(slug: entries.map { |e| e[:slug] }).all.to_h { |f| [f.slug, f] }

    DB.transaction do
      missing = entries.reject { |e| films.key?(e[:slug]) }.uniq { |e| e[:slug] }
      unless missing.empty?
        # created_at by hand: this writes through the dataset rather than the
        # model, so the timestamps plugin never sees it, and /cache orders the
        # films it holds by that column.
        now = Time.now
        DB[:films].import(%i[slug title year created_at],
                          missing.map { |e| [e[:slug], e[:title], e[:year], now] })
        Film.where(slug: missing.map { |e| e[:slug] }).each { |f| films[f.slug] = f }
      end

      # Titles get corrected upstream occasionally; keep ours current.
      entries.each do |e|
        film = films[e[:slug]]
        film.update(title: e[:title], year: e[:year]) if film.title != e[:title] || film.year != e[:year]
      end
    end

    entries.map { |e| films[e[:slug]].id }
  end

  # Persists a fetched watchlist, replacing whatever that user had before.
  def store!(user, entries)
    now = Time.now
    film_ids = film_ids_for(entries)

    DB.transaction do
      DB[:watchlist_entries].where(user_id: user.id).delete
      DB[:watchlist_entries].import(
        %i[user_id film_id fetched_at],
        film_ids.map { |fid| [user.id, fid, now] }
      )
    end

    film_ids.size
  end

  # Records films this member has watched. Unlike a watchlist this is never
  # replaced, only added to: every source of it (the 72-film page, an uploaded
  # export, a per-film check) is partial, and a film missing from one of them
  # means "not in this batch", not "not watched".
  # One transaction, like store! next door: an import that dies halfway should
  # leave nothing behind rather than a history with a hole in it.
  def store_watched!(user, entries)
    DB.transaction { Seen.record_seen!(user.id, film_ids_for(entries)) }
  end

  # Persists a club's fixed list, preserving list order.
  def store_list!(club, entries)
    now = Time.now
    film_ids = film_ids_for(entries)

    DB.transaction do
      DB[:club_list_entries].where(club_id: club.id).delete
      DB[:club_list_entries].import(
        %i[club_id film_id position fetched_at],
        film_ids.each_with_index.map { |fid, i| [club.id, fid, i + 1, now] }
      )
    end

    film_ids.size
  end

  # Refreshes the data the matcher actually reads, and nothing else: the
  # watchlists of members of active clubs that draw on watchlists, the list
  # behind each active list-mode club, and — for those clubs only — who has
  # already watched what. Somebody who is only ever in a list-mode club is never
  # scraped for a watchlist, because their watchlist is never consulted.
  #
  # One failure must not stop the rest — this runs unattended.
  def refresh_all!(pace: :background, force: false)
    users = watchlist_users
    warn "[fetch] nobody with a Letterboxd account in a watchlist club yet" if users.empty?

    due, fresh = force ? [users, []] : users.partition { |u| stale_watchlist?(u) }
    puts "[fetch] #{due.size} watchlist#{due.size == 1 ? '' : 's'} due, #{fresh.size} still fresh" if users.any?

    list_clubs = Club.where(active: true, list_mode: "list").exclude(list_slug: nil).all
    clubs = force ? list_clubs : list_clubs.select { |c| stale_list?(c) }

    # Shuffled so it isn't the same person first every night, and so a run that
    # dies halfway doesn't die on the same half twice.
    jobs = due.shuffle.map { |u| -> { refresh_user!(u, pace: pace) } } +
           clubs.shuffle.map { |c| -> { refresh_list!(c, pace: pace) } } +
           # One request each, so these run every time rather than on a
           # freshness clock: 72 recent films per member is the cheapest seen
           # data there is.
           watched_users.shuffle.map { |u| -> { refresh_watched!(u) } } +
           list_clubs.shuffle.map { |c| -> { warm_seen!(c, pace: pace, force: force) } }

    jobs.each_with_index do |job, i|
      # The stagger is the whole point: one member's watchlist finishes, then
      # we go quiet for minutes before the next one starts.
      pause(pace == :background ? MEMBER_STAGGER : PACE.fetch(pace)) if i.positive?
      job.call
    end
  end

  # Members whose watchlists feed a ballot somewhere.
  def watchlist_users
    club_ids = Club.where(active: true).exclude(list_mode: "list").select(:id)
    user_ids = Membership.where(club_id: club_ids).distinct.select_map(:user_id)
    User.where(id: user_ids).reachable.exclude(letterboxd_username: nil).all
  end

  # The mirror image: members whose *watch history* decides a ballot, which is
  # only ever a list-mode club's.
  # A club with no list on it yet can't put anything on a ballot, so its
  # members' histories aren't worth a request — the same exclusion refresh_all!
  # applies before fetching the lists themselves.
  def watched_users
    club_ids = Club.where(active: true, list_mode: "list").exclude(list_slug: nil).select(:id)
    user_ids = Membership.where(club_id: club_ids).distinct.select_map(:user_id)
    User.where(id: user_ids).reachable.exclude(letterboxd_username: nil).all
  end

  def stale_watchlist?(user)
    last = user.watchlist_fetched_at
    last.nil? || last < Time.now - REFRESH_AFTER
  end

  def stale_list?(club)
    last = DB[:club_list_entries].where(club_id: club.id).order(Sequel.desc(:fetched_at)).get(:fetched_at)
    last.nil? || last < Time.now - REFRESH_AFTER
  end

  def refresh_user!(user, pace: :interactive)
    entries = watchlist(user.letterboxd_username, pace: pace)

    if entries.empty?
      # An empty watchlist and a private one are indistinguishable: both are
      # HTTP 200 with zero entries. Say so loudly rather than silently
      # contributing nothing to matching forever.
      warn "[fetch] #{user.email} (#{user.letterboxd_username}): 0 films — " \
           "watchlist is empty or not public. Keeping previous data."
      return nil
    end

    count = store!(user, entries)
    puts "[fetch] #{user.email} (#{user.letterboxd_username}): #{count} films"
    count
  rescue RateLimited => e
    warn "[fetch] #{user.email}: rate-limited, skipping — #{e.message}"
    nil
  rescue *TRANSPORT_ERRORS => e
    warn "[fetch] #{user.email}: #{e.class}: #{e.message}"
    nil
  end

  def refresh_list!(club, pace: :interactive)
    entries = list(club.list_owner, club.list_slug, pace: pace)
    if entries.empty?
      warn "[fetch] club #{club.slug}: list #{club.list_url} is empty or private. Keeping previous data."
      return nil
    end

    count = store_list!(club, entries)
    puts "[fetch] club #{club.slug}: #{count} films from #{club.list_url}"
    count
  rescue *TRANSPORT_ERRORS => e
    warn "[fetch] club #{club.slug}: #{e.class}: #{e.message}"
    nil
  end

  # One request: the member's 72 most recent films, straight into the seen
  # cache. Cheap enough to do every run, and it keeps a club's list filtered
  # against what people are watching now without any per-film checking.
  def refresh_watched!(user)
    entries = recent_films(user.letterboxd_username)

    if entries.empty?
      # Either they've logged nothing, or the markup moved under us. Say so:
      # this is the cheapest seen data there is, and it would otherwise go
      # quiet for good without a line in the log.
      warn "[fetch] #{user.email} (#{user.letterboxd_username}): 0 recently watched — " \
           "nothing logged, or the films page changed shape."
      return nil
    end

    count = store_watched!(user, entries)
    puts "[fetch] #{user.email} (#{user.letterboxd_username}): #{count} recently watched"
    count
  rescue NotFound
    # A renamed or deleted account. Their other jobs are already skipped by the
    # same 404, and the rest of the night's work isn't ours to take down.
    warn "[fetch] #{user.email}: no such Letterboxd account (#{user.letterboxd_username})"
    nil
  rescue RateLimited => e
    warn "[fetch] #{user.email}: watched list rate-limited, skipping — #{e.message}"
    nil
  rescue *TRANSPORT_ERRORS => e
    warn "[fetch] #{user.email}: watched list #{e.class}: #{e.message}"
    nil
  end

  # Works through a list-mode club's list asking "has this member watched it?",
  # one film and one member at a time, until the budget runs out.
  #
  # Two things keep the cost down. A film is dropped the moment one member says
  # yes — the ballot rule is that nobody has seen it, so the rest of the club
  # needn't be asked. And a club with Seen::RESERVE ballots' worth of verified
  # film already in hand is skipped entirely, so this is a cost while a club is
  # new and nothing once it has settled.
  def warm_seen!(club, pace: :background, force: false, budget: SEEN_BUDGET)
    users = club.linked_members
    return 0 if users.empty?

    user_ids = users.map(&:id)
    if !force && Seen.stocked?(club, user_ids)
      puts "[seen] club #{club.slug}: #{Seen.verified_unseen_count(club, user_ids)} films verified unseen — nothing to do"
      return 0
    end

    spent = check_films!(club, users, pace: pace, budget: budget)
    puts "[seen] club #{club.slug}: #{spent} check#{spent == 1 ? '' : 's'}, " \
         "#{Seen.verified_unseen_count(club, user_ids)} films verified unseen"
    spent
  end

  def check_films!(club, users, pace:, budget:)
    spent = 0
    film_ids = Seen.to_check(club, users.map(&:id), limit: budget)
    films = Film.where(id: film_ids).all.to_h { |f| [f.id, f] }
    pending = Seen.unchecked_users_by_film(film_ids, users)

    film_ids.each do |film_id|
      film = films[film_id]
      next if film.nil?

      pending.fetch(film_id, []).each do |user|
        break if spent >= budget

        pause(PACE.fetch(pace)) if spent.positive?
        spent += 1
        seen = logged?(user.letterboxd_username, film.slug)
        Seen.record!(user_id: user.id, film_id: film_id, seen: seen)
        # One 'yes' settles the film: it can't reach the ballot either way.
        break if seen
      rescue RateLimited => e
        # Rescued ahead of the transport errors, and fatal to this club rather
        # than to the run: challenged once means challenged for the next
        # request too, and every remaining job in the night is somebody else's.
        warn "[seen] club #{club.slug}: rate-limited after #{spent} check#{spent == 1 ? '' : 's'} — #{e.message}"
        return spent
      rescue *TRANSPORT_ERRORS => e
        # No row written, so the film comes round again next run.
        warn "[seen] club #{club.slug}: #{user.letterboxd_username}/#{film.slug} #{e.class}: #{e.message}"
      end

      break if spent >= budget
    end

    spent
  end

  # Cheap single-request check used at signup, before we trust a username.
  # Returns the film count.
  def check(username)
    doc = Nokogiri::HTML(get("#{BASE}/#{username}/watchlist/page/1/"))
    doc.css("[data-item-slug]").size
  end

  # Confirms a list exists and returns its film count.
  def check_list(owner, slug)
    doc = Nokogiri::HTML(get("#{BASE}/#{owner}/list/#{slug}/page/1/"))
    doc.css("[data-item-slug]").size
  end

  def parse_display_name(name)
    s = name.to_s.strip
    (m = DISPLAY_NAME.match(s)) ? [m[1].strip, Integer(m[2])] : [s, nil]
  end

  def slugify(name, year)
    base = name.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")
    year.to_s =~ /\A\d{4}\z/ ? "#{base}-#{year}" : base
  end

  def get(url)
    uri = URI(url)
    req = Net::HTTP::Get.new(uri)
    req["User-Agent"] = USER_AGENT
    req["Accept"] = "text/html,application/xhtml+xml"
    req["Accept-Language"] = "en-US,en;q=0.9"

    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                                              open_timeout: 15, read_timeout: 30) do |http|
      http.request(req)
    end

    case res
    when Net::HTTPForbidden, Net::HTTPServiceUnavailable
      raise RateLimited, "HTTP #{res.code} for #{url}"
    when Net::HTTPNotFound
      raise NotFound, "no such page: #{url}"
    when Net::HTTPSuccess
      body = res.body.to_s.byteslice(0, MAX_BODY_BYTES)
      # A 200 can still be a challenge page under Cloudflare's own markup.
      raise RateLimited, "challenge interstitial for #{url}" if body.include?(CHALLENGE_MARKER)

      body
    else
      raise Error, "unexpected HTTP #{res.code} for #{url}"
    end
  end
end
