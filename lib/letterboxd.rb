# Reads public Letterboxd pages.
#
# Letterboxd's API is request-only and they decline personal projects, so this
# reads the public pages instead:
#
#   watchlist(user)        /{user}/watchlist/page/{n}/     — films they want
#   list(owner, slug)      /{owner}/list/{slug}/page/{n}/  — a curated list
#   film_details(slug)     /film/{slug}/                   — director, rating, TMDB id
#   avatar(user)           /{user}/watchlist/page/1/       — their profile picture
#   recent_logs(user)      /{user}/rss/                    — what they've watched lately
#   watched_films(user)    /{user}/films/                  — what they've watched, page 1
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
# Watch history comes from three places: an uploaded watched.csv, the RSS feed,
# and the first page of /{user}/films/.
#
# The films page is in because it is the only one of the three that sees a film
# somebody rated without ever logging a diary entry — and a rating marks a film
# watched, so those are real. Measured 2026-08-21 on an account with seven
# ratings and no diary: the feed came back an empty <channel>, the films page
# listed all seven. Its limits are real and survivable. It sorts by release date
# rather than by when anything was logged, and page 2 onwards is challenged, so
# a heavy user gives up their 72 newest-released films and no more — but that's
# 72 true positives a request, and lib/seen.rb only ever promotes, so reading
# half a history costs nothing. The `.paginate-pages` block says which we got:
# no such block means the account has 72 films or fewer and we read the lot.
#
# Every re-sort of it is still shut — /page/2/, /by/rated-date/, /films/ratings/
# and /films/diary/ are all 403 behind a Cloudflare interstitial (re-checked
# 2026-08-21) — and so is the one page that would date a rating rather than just
# report it: /{user}/activity/ is a 200 shell whose contents come from
# /ajax/activity-pagination/{user}/, which is challenged, as is /{user}/ itself.
#
# /{user}/film/{slug}/ answers per film, but 404s for plenty of films people
# have genuinely watched (of twelve an account's own watched.csv listed, three
# came back 404 — measured 2026-08-10), so it costs a request each to be wrong.
# That one is gone.

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

  # The films a member has logged most recently, newest first.
  #
  # The RSS feed, because it is the only route Letterboxd leaves open that is
  # ordered by *when something was logged*. /{user}/films/ looks like the right
  # page and isn't: it sorts by release date (measured 2026-08-10 — the years
  # come back perfectly non-increasing on an account with hundreds logged), so
  # it's a window on new releases and nothing else, returning much the same page
  # night after night while a member working through a list of classics never
  # appears in it. Every form of it that would re-sort or paginate — /page/2/,
  # /by/date/, /by/entry-rating/, /year/1978/, /films/diary/ — is 403 with
  # `cf-mitigated: challenge` (re-checked 2026-08-10).
  #
  # About 50 entries, which is weeks of logging for most people — comfortably
  # longer than a round. Entries that aren't films (lists, follows) carry no
  # /film/ link and drop out here.
  #
  # Same shape as `parse_entries`, since it feeds the same two places: the seen
  # cache, which wants titles to match films on, and lib/rounds.rb, which only
  # wants the slugs.
  def recent_logs(username)
    Nokogiri::XML(get("#{BASE}/#{username}/rss/")).css("item").filter_map do |item|
      slug = item.at_css("link")&.text.to_s[%r{/film/([^/]+)/}, 1]
      next if slug.nil?

      # The letterboxd: namespace carries the title and year apart, which beats
      # unpicking "Heavy Metal, 1981 - ★★★★" out of the item title. Matched on
      # local name because the prefix is only bound in the feed's own root, and
      # a hand-built XML fragment (a test, a future feed) needn't declare it. A
      # diary entry always has both; anything that somehow doesn't falls back to
      # the slug, which film_ids_for can still match on.
      title = child_text(item, "filmTitle")
      year = child_text(item, "filmYear")
      { slug: slug,
        title: title.empty? ? slug : title,
        year: (Integer(year) if year =~ /\A\d{4}\z/) }
    end
  end

  def child_text(node, name)
    node.at_xpath("./*[local-name()='#{name}']")&.text.to_s.strip
  end

  # The first page of the films a member has watched, and whether that was all
  # of them.
  #
  # The companion to `recent_logs` rather than a duplicate of it: this is the
  # only route that sees a film somebody rated without logging a diary entry,
  # which never reaches the feed at all. Ordered by release date, so it is not a
  # window on what they've been watching lately — it's a slice of the whole
  # history weighted towards new releases, which is the half the feed is worst
  # at, and worth a request for exactly that reason.
  #
  # `complete` is false when Letterboxd offered a page 2 we aren't allowed to
  # fetch. It only decides what the log line says: every entry here is watched
  # either way, and a short read is still all yeses.
  def watched_films(username)
    doc = Nokogiri::HTML(get("#{BASE}/#{username}/films/"))
    { entries: parse_entries(doc), complete: doc.at_css(".paginate-pages").nil? }
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
  # to get a member's whole history, since the feed only reaches back about 50
  # entries and nothing else Letterboxd leaves open serves a history in bulk
  # (see lib/seen.rb). Everything in the file is a film they've watched, so it
  # lands in the seen cache wholesale.
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

  # Upserts films. Films are shared across users and clubs, so they're never
  # deleted here.
  #
  # Slug first, then Film.match_key — normalised title and year. Matching on
  # slug alone was wrong: watched.csv gives a boxd.it short link rather than a
  # film path, so every imported film fell back to a slug built from its title
  # and became a second row for a film we already had, invisible to anything
  # holding the first one. That's how a member's imported history stopped
  # filtering a list club's ballot. See db/migrate/010_film_match_keys.rb, which
  # merged the rows this had already split.
  #
  # Two queries for the lot rather than a round-trip each: an imported history
  # runs to thousands of films, and this happens inside a web request.
  def film_ids_for(entries)
    by_slug = Film.where(slug: entries.map { |e| e[:slug] }).all.to_h { |f| [f.slug, f] }
    keys = entries.filter_map { |e| Film.match_key(e[:title], e[:year]) }.uniq
    by_key = {}
    # Oldest wins, so which film an entry resolves to doesn't depend on the
    # order rows come back in. The migration left no duplicate keys behind, but
    # two genuinely distinct films can share a title and a year, and it made no
    # attempt to merge those.
    Film.where(match_key: keys).order(:id).each { |f| by_key[f.match_key] ||= f } unless keys.empty?

    # Resolved once, up front, rather than looked up again at the end: the pass
    # below rewrites the very slugs these were matched on, so asking twice would
    # get two different answers.
    #
    # Once per distinct slug, and the answer is reused: a slug is Letterboxd's
    # identity for a film, so two entries carrying one are the same film however
    # much their titles differ. Resolving them separately would put the second
    # in `missing` and insert a row for a slug the first is about to adopt —
    # a UNIQUE violation out of a member's upload.
    claimed = {}
    found = entries.map do |e|
      claimed.fetch(e[:slug]) { claimed[e[:slug]] = existing_film(e, by_slug, by_key) }
    end

    DB.transaction do
      missing = entries.each_index.reject { |i| found[i] }.uniq { |i| entries[i][:slug] }
      unless missing.empty?
        # created_at and match_key by hand: this writes through the dataset
        # rather than the model, so neither the timestamps plugin nor Film's
        # before_save hook sees it. /cache orders the films it holds by
        # created_at.
        now = Time.now
        DB[:films].import(%i[slug title year match_key created_at],
                          missing.map do |i|
                            e = entries[i]
                            [e[:slug], e[:title], e[:year], Film.match_key(e[:title], e[:year]), now]
                          end)
        fresh = Film.where(slug: missing.map { |i| entries[i][:slug] }).all.to_h { |f| [f.slug, f] }
        entries.each_with_index { |e, i| found[i] ||= fresh.fetch(e[:slug]) }
      end

      entries.each_with_index do |e, i|
        film = found[i]
        # Titles get corrected upstream occasionally; keep ours current.
        # Through the model, so match_key follows the title.
        film.update(title: e[:title], year: e[:year]) if film.title != e[:title] || film.year != e[:year]
        adopt_slug!(film, e[:slug])
      end
    end

    # Deduplicated because two entries can now land on one film — a list that
    # carries both a film and the row an import invented for it, say. Nothing
    # downstream wants the same film twice, and both of the tables these ids
    # reach have it as half of a primary key.
    found.map(&:id).uniq
  end

  # The film an entry already has a row for, or nil.
  #
  # Slug is exact and settles it. Failing that the key does, but only when one
  # side's slug was invented — that is, when it's exactly the key it would have
  # been built from. Two *real* slugs that share a title and a year are two
  # films: Letterboxd hands a short and a feature of the same name and year
  # different slugs, and collapsing them would lose one for good.
  #
  # A key match is consumed, so only the first slug to reach it takes it. The
  # rest is the same rule read the other way: a short and a feature sharing a
  # title and a year both key to the invented row an import left behind, and
  # letting both have it would collapse the pair that the rule above exists to
  # keep apart. The loser matches nothing and gets a row of its own.
  def existing_film(entry, by_slug, by_key)
    return by_slug[entry[:slug]] if by_slug.key?(entry[:slug])

    key = Film.match_key(entry[:title], entry[:year])
    film = by_key[key]
    return nil unless film && (entry[:slug] == key || film.slug == key)

    by_key.delete(key)
    film
  end

  # A film first seen in an import has a slug we invented, and every use of a
  # slug — the Letterboxd link, the details fetch, the watched check — needs the
  # real one. So when a scrape later turns up the same film by key, it hands its
  # slug over.
  #
  # The invented slug is exactly the match key, which is what it was built from,
  # so that equality is the whole test for "we made this up". A real slug can
  # look the same (Letterboxd disambiguates with the year too), but then it's
  # already right and there's nothing to adopt.
  #
  # Details are dropped with the slug: anything fetched under the invented one
  # was fetched from a 404, so there's nothing there worth keeping and a stale
  # `details_fetched_at` would stop lib/films.rb going back for the real thing.
  def adopt_slug!(film, slug)
    return if slug == film.slug || film.match_key.nil? || film.slug != film.match_key

    film.update(slug: slug, details_fetched_at: nil)
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
  # replaced, only added to: both sources of it (the feed, an uploaded export)
  # are partial, and a film missing from one of them means "not in this batch",
  # not "not watched".
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
           # Two requests each, so these run every time rather than on a
           # freshness clock: a member's feed is the cheapest seen data there
           # is, and a night missed is a week of logging we never pick up.
           watched_users.shuffle.map { |u| -> { refresh_watched!(u, pace: pace) } }

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

  # Two requests: whatever the member has logged lately, off their feed, and the
  # first page of their watched films, which is the only place a rating with no
  # diary entry behind it turns up. Both land in the same seen cache. Cheap
  # enough to do every run, and it keeps a club's list filtered against what
  # people are actually watching.
  #
  # They answer different questions and neither subsumes the other. The feed
  # reaches back about 50 entries ordered by when they were logged, so nightly
  # runs cover everything short of somebody logging fifty films in a day, at any
  # age of film — but it is blind to a rating on its own. The films page sees
  # those, and has no recency at all: it returns much the same slice night after
  # night until the member watches something newly released. Neither reaches the
  # history they had before joining; that's what the import is for.
  #
  # Fetched independently so a challenge on one still banks the other, and
  # merged on slug, since a film they logged *and* rated is in both.
  def refresh_watched!(user, pace: :interactive)
    username = user.letterboxd_username

    logged = fetch_watched(user, "feed at /#{username}/rss/") { recent_logs(username) }
    pause(PACE.fetch(pace))
    films = fetch_watched(user, "films page at /#{username}/films/") { watched_films(username) }

    # Both refused, and both have already said so. Nothing to add.
    return nil if logged.nil? && films.nil?

    entries = (logged.to_a + (films ? films[:entries] : [])).uniq { |e| e[:slug] }

    if entries.empty?
      # Two pages that both answered, both empty: they've logged and rated
      # nothing, or both changed shape under us. Say so, because this is the
      # cheapest seen data there is and would otherwise go quiet for good.
      warn "[fetch] #{user.email} (#{username}): 0 watched — " \
           "nothing logged or rated, or both pages changed shape."
      return nil
    end

    count = store_watched!(user, entries)
    short = films && !films[:complete] ? " (films page cut off after page 1)" : ""
    puts "[fetch] #{user.email} (#{username}): #{count} watched#{short}"
    count
  end

  # Runs one of the two, turning every way Letterboxd can refuse into nil and a
  # line in the log. Nil rather than an exception because the two are
  # independent: a challenged films page mustn't throw away a feed we've already
  # read, and neither is worth taking the night's other work down for.
  def fetch_watched(user, what)
    yield
  rescue NotFound
    # A renamed or deleted account — or, for the feed, a member who has logged
    # nothing at all and so has no feed to serve. A renamed account's other jobs
    # are skipped by the same 404.
    warn "[fetch] #{user.email}: no #{what} — renamed account, or nothing there yet"
    nil
  rescue RateLimited => e
    warn "[fetch] #{user.email}: #{what} rate-limited, skipping — #{e.message}"
    nil
  rescue *TRANSPORT_ERRORS => e
    warn "[fetch] #{user.email}: #{what} #{e.class}: #{e.message}"
    nil
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

  # The slug for a film an export didn't give us one for. Film.match_key by
  # definition, not merely by coincidence: everything that has to recognise an
  # invented slug later — film_ids_for, adopt_slug!, migration 010 — does it by
  # asking whether the slug is the film's own key, and that test is only sound
  # while these two agree.
  def slugify(name, year)
    Film.match_key(name, year) || name.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")
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
