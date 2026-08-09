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
require "uri"
require "csv"
require "json"
require "nokogiri"

require_relative "models"

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

  # The title Cloudflare puts on its challenge interstitial. It can arrive
  # under a 200, not just a 403.
  CHALLENGE_MARKER = "Just a moment"

  USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " \
               "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

  Error = Class.new(StandardError)

  # Letterboxd served a Cloudflare interstitial. Retrying immediately won't help.
  RateLimited = Class.new(Error)
  NotFound = Class.new(Error)

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

  def walk(base_path, pace: :interactive)
    entries = []
    seen = Set.new

    (1..MAX_PAGES).each do |page|
      doc = Nokogiri::HTML(get("#{base_path}/page/#{page}/"))
      found = 0

      doc.css("[data-item-slug]").each do |node|
        slug = node["data-item-slug"].to_s
        next if slug.empty? || seen.include?(slug)

        name = node["data-item-full-display-name"] || node["data-item-name"]
        next if name.to_s.strip.empty?

        title, year = parse_display_name(name)
        seen << slug
        entries << { slug: slug, title: title, year: year }
        found += 1
      end

      yield(page, entries.size) if block_given?

      # Walking past the end returns the page shell with no entries, not a 404.
      break if found.zero?

      pause(PACE.fetch(pace))
    end

    entries
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

  # Upserts films by slug. Films are shared across users and clubs, so they're
  # never deleted here.
  def film_ids_for(entries)
    entries.map do |e|
      film = Film.first(slug: e[:slug])
      if film
        # Titles get corrected upstream occasionally; keep ours current.
        film.update(title: e[:title], year: e[:year]) if film.title != e[:title] || film.year != e[:year]
        film.id
      else
        Film.create(slug: e[:slug], title: e[:title], year: e[:year]).id
      end
    end
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
  # watchlists of members of active clubs that draw on watchlists, plus the
  # list behind each active list-mode club. Somebody who is only ever in a
  # list-mode club is never scraped — their watchlist is never consulted.
  #
  # One failure must not stop the rest — this runs unattended.
  def refresh_all!(pace: :background, force: false)
    users = watchlist_users
    warn "[fetch] nobody with a Letterboxd account in a watchlist club yet" if users.empty?

    due, fresh = force ? [users, []] : users.partition { |u| stale_watchlist?(u) }
    puts "[fetch] #{due.size} watchlist#{due.size == 1 ? '' : 's'} due, #{fresh.size} still fresh" if users.any?

    clubs = Club.where(active: true, list_mode: "list").exclude(list_slug: nil).all
    clubs = clubs.select { |c| stale_list?(c) } unless force

    # Shuffled so it isn't the same person first every night, and so a run that
    # dies halfway doesn't die on the same half twice.
    jobs = due.shuffle.map { |u| -> { refresh_user!(u, pace: pace) } } +
           clubs.shuffle.map { |c| -> { refresh_list!(c, pace: pace) } }

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
  rescue Error, SocketError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout => e
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
  rescue Error, SocketError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout => e
    warn "[fetch] club #{club.slug}: #{e.class}: #{e.message}"
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
