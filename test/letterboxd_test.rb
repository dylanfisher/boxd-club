# Reading Letterboxd: parsing the pages, walking them, and taking an uploaded
# export. Nothing here touches the network — test/helper.rb refuses that
# outright, so a stub that goes missing fails rather than reaching the site.

require_relative "helper"

class LetterboxdTest < BoxdTest
  # -- parsing a listing page ------------------------------------------------

  def test_films_are_read_off_a_listing_page_in_page_order
    entries = Letterboxd.parse_entries(Nokogiri::HTML(fixture("watchlist_page.html")))

    assert_equal %w[operation-mincemeat-2022 citizen-kane stalker],
                 entries.map { |e| e[:slug] }
  end

  # The slug says 2022 and the display name says 2021. The display name wins.
  def test_the_display_year_beats_the_year_in_the_slug
    first = Letterboxd.parse_entries(Nokogiri::HTML(fixture("watchlist_page.html"))).first

    assert_equal "Operation Mincemeat", first[:title]
    assert_equal 2021, first[:year]
  end

  def test_an_entry_with_no_year_keeps_its_title
    stalker = Letterboxd.parse_entries(Nokogiri::HTML(fixture("watchlist_page.html")))
                        .find { |e| e[:slug] == "stalker" }

    assert_equal "Stalker", stalker[:title]
    assert_nil stalker[:year]
  end

  def test_entries_with_no_slug_or_no_name_are_dropped
    slugs = Letterboxd.parse_entries(Nokogiri::HTML(fixture("watchlist_page.html"))).map { |e| e[:slug] }

    refute_includes slugs, "a-film-with-no-name"
    assert_equal 3, slugs.size
  end

  # -- the RSS feed ----------------------------------------------------------

def test_recent_logs_reads_the_feed_newest_first
  entries = stub_letterboxd("/rss/" => fixture("rss_feed.xml")) do
    Letterboxd.recent_logs("dylan_fisher")
  end

  assert_equal %w[heavy-metal vertigo new-rose-hotel], entries.map { |e| e[:slug] }
  assert_equal ["Heavy Metal", 1981], entries.first.values_at(:title, :year),
               "the letterboxd: namespace carries the title and year apart"
end

# Follows, likes and list activity share the feed and carry no film link.
def test_recent_logs_drops_entries_that_are_not_films
  feed = <<~XML
    <rss version="2.0"><channel>
      <link>https://letterboxd.com/someone/</link>
      <item><link>https://letterboxd.com/someone/list/best-of-2026/</link></item>
      <item><link>https://letterboxd.com/someone/film/stalker/</link></item>
    </channel></rss>
  XML

  entries = stub_letterboxd("/rss/" => feed) { Letterboxd.recent_logs("someone") }

  assert_equal ["stalker"], entries.map { |e| e[:slug] },
               "the channel link and the list entry are not films"
  assert_equal "stalker", entries.first[:title], "no film title in the item, so the slug stands in"
end

  def test_parse_display_name
    assert_equal ["Citizen Kane", 1941], Letterboxd.parse_display_name("Citizen Kane (1941)")
    assert_equal ["Se7en", nil], Letterboxd.parse_display_name("Se7en")
    # A title that ends in a bracketed number that isn't a year.
    assert_equal ["Fahrenheit 9/11 (911)", nil], Letterboxd.parse_display_name("Fahrenheit 9/11 (911)")
  end

  # -- walking pages ---------------------------------------------------------

  def test_walking_stops_at_the_first_page_that_adds_nothing
    pages = { 1 => %w[a b], 2 => %w[c], 3 => [] }
    asked = []

    stub_method(Letterboxd, :get, lambda { |url|
      page = url[%r{/page/(\d+)/}, 1].to_i
      asked << page
      poster_page(pages.fetch(page, []))
    }) do
      entries = Letterboxd.watchlist("someone")
      assert_equal %w[a b c], entries.map { |e| e[:slug] }
    end

    assert_equal [1, 2, 3], asked, "and it stops there rather than walking on"
  end

  # Letterboxd repeats entries across pages when the list changes mid-walk.
  def test_a_film_repeated_across_pages_is_only_taken_once
    stub_method(Letterboxd, :get, lambda { |url|
      url.include?("/page/1/") ? poster_page(%w[a b]) : poster_page(%w[b])
    }) do
      assert_equal %w[a b], Letterboxd.watchlist("someone").map { |e| e[:slug] }
    end
  end

  # -- what the HTTP layer makes of a response -------------------------------

  def test_a_challenge_page_is_a_rate_limit_even_under_a_200
    body = "<html><head><title>Just a moment...</title></head></html>"

    stub_http(http_response(Net::HTTPOK, "200", body)) do
      assert_raises(Letterboxd::RateLimited) { Letterboxd.get("#{Letterboxd::BASE}/x/") }
    end
  end

  def test_status_codes_become_the_right_errors
    {
      Net::HTTPForbidden => ["403", Letterboxd::RateLimited],
      Net::HTTPServiceUnavailable => ["503", Letterboxd::RateLimited],
      Net::HTTPNotFound => ["404", Letterboxd::NotFound],
      Net::HTTPInternalServerError => ["500", Letterboxd::Error]
    }.each do |klass, (code, error)|
      stub_http(http_response(klass, code)) do
        assert_raises(error, "HTTP #{code}") { Letterboxd.get("#{Letterboxd::BASE}/x/") }
      end
    end
  end

  def test_an_overlong_body_is_cut_rather_than_read_whole
    body = "x" * (Letterboxd::MAX_BODY_BYTES + 1000)

    stub_http(http_response(Net::HTTPOK, "200", body)) do
      assert_equal Letterboxd::MAX_BODY_BYTES, Letterboxd.get("#{Letterboxd::BASE}/x/").bytesize
    end
  end

  # -- avatars ---------------------------------------------------------------

  def test_an_avatar_is_read_off_the_watchlist_page_and_asked_for_larger
    stub_letterboxd("watchlist" => fixture("watchlist_page.html")) do
      assert_equal "https://a.ltrbxd.com/resized/avatar/upload/1/2/3/4/" \
                   "avtr-0-220-0-220-crop.jpg?v=abc123",
                   Letterboxd.avatar("someone")
    end
  end

  def test_the_stock_silhouette_counts_as_no_avatar
    page = '<html><body><a class="avatar"><img src="https://s.ltrbxd.com/static/img/avatar.png"></a></body></html>'

    stub_letterboxd("watchlist" => page) do
      assert_nil Letterboxd.avatar("someone")
    end
  end

  # -- film details ----------------------------------------------------------

  def test_film_details_come_off_the_film_page
    stub_letterboxd("/film/stalker/" => fixture("film_page.html")) do
      details = Letterboxd.film_details("stalker")

      assert_equal "Andrei Tarkovsky", details[:director]
      assert_in_delta 4.42, details[:rating]
      assert_equal 1398, details[:tmdb_id]
      assert_match %r{film-poster}, details[:poster_url]
      # The 2x still, not the 1200px one.
      assert_equal "https://a.ltrbxd.com/resized/sm/upload/backdrop-1920.jpg", details[:backdrop_url]
    end
  end

  def test_a_film_page_with_none_of_it_yields_nils_rather_than_raising
    stub_letterboxd("/film/x/" => "<html><body>nothing here</body></html>") do
      details = Letterboxd.film_details("x")

      assert_nil details[:director]
      assert_nil details[:rating]
      assert_nil details[:backdrop_url]
      assert_nil details[:poster_url]
    end
  end

  def test_unreadable_ld_json_does_not_take_the_page_down
    page = '<html><head><script type="application/ld+json">{"director": oops</script></head>' \
           '<body><a href="/director/chantal-akerman/">Chantal Akerman</a></body></html>'

    stub_letterboxd("/film/x/" => page) do
      # Falls back to the director links on the page itself.
      assert_equal "Chantal Akerman", Letterboxd.film_details("x")[:director]
    end
  end

  # -- exports ---------------------------------------------------------------

  # db/seeds/watchlists/*.csv are real exports, kept for the demo seed.
  def test_a_real_export_parses
    entries = Letterboxd.from_csv(File.read("db/seeds/watchlists/sidneyprescott.csv"))

    assert_equal 69, entries.size
    # A title that is entirely digits, which is the row that catches a parser
    # doing anything clever with the Name column.
    assert_equal({ slug: "31-2016", title: "31", year: 2016 }, entries.first)
    assert_includes entries, { slug: "a-little-princess-1995", title: "A Little Princess", year: 1995 }
  end

  def test_a_title_with_a_comma_in_it_survives_the_csv
    csv = <<~CSV
      Name,Year,Letterboxd URI
      "Cloudy with a Chance of Meatballs, Part 2",2013,https://letterboxd.com/film/cloudy-2/
    CSV

    assert_equal "Cloudy with a Chance of Meatballs, Part 2", Letterboxd.from_csv(csv).first[:title]
  end

  def test_a_short_link_export_falls_back_to_a_slug_from_the_title
    csv = "Name,Year,Letterboxd URI\nCitizen Kane,1941,https://boxd.it/2a1c\n"

    assert_equal "citizen-kane-1941", Letterboxd.from_csv(csv).first[:slug]
  end

  def test_the_same_film_twice_in_an_export_is_read_once
    csv = "Name,Year,Letterboxd URI\n" \
          "Stalker,1979,https://letterboxd.com/film/stalker/\n" \
          "Stalker,1979,https://letterboxd.com/film/stalker/\n"

    assert_equal 1, Letterboxd.from_csv(csv).size
  end

  # The nightly fetch's whole seen path for a member: one request to their feed,
  # straight into the cache, films created for anything we hadn't heard of.
  def test_the_nightly_fetch_reads_the_feed_into_the_seen_cache
    member = user(username: "dylan_fisher")

    count = stub_letterboxd("/rss/" => fixture("rss_feed.xml")) do
      Letterboxd.refresh_watched!(member)
    end

    assert_equal 3, count
    assert_equal 3, Seen.user_count(member.id)
    assert_equal %w[heavy-metal new-rose-hotel vertigo],
                 Film.where(id: DB[:seen_checks].where(user_id: member.id).select(:film_id))
                     .select_map(:slug).sort
    assert_equal 1981, Film.first(slug: "heavy-metal").year
  end

  # A member who has logged nothing has no feed at all. That's not a reason to
  # take the rest of the night's work down.
  def test_a_member_with_no_feed_does_not_stop_the_fetch
    member = user(username: "nobody")

    assert_nil stub_letterboxd({}) { Letterboxd.refresh_watched!(member) }
  end

  # -- uploading a watch history ---------------------------------------------

  def test_importing_a_watched_export_records_what_they_have_seen
    member = user
    csv = "Name,Year,Letterboxd URI\n" \
          "Stalker,1979,https://letterboxd.com/film/stalker/\n" \
          "Solaris,1972,https://letterboxd.com/film/solaris/\n"

    result = Letterboxd.import_watched!(member, StringIO.new(csv), filename: "watched.csv")

    assert_equal 2, result[:read]
    assert_equal 2, result[:on_file]
    assert_equal 2, Seen.user_count(member.id)
    refute_nil member.refresh.watched_imported_at
  end

  # The two export files have identical columns, so importing the wrong one
  # would mark every film they *want* to see as already seen.
  def test_a_film_still_on_their_watchlist_is_not_recorded_as_watched
    member = user
    wanted = Film.create(slug: "stalker", title: "Stalker", year: 1979, created_at: Time.now)
    watchlist(member, [wanted])
    csv = "Name,Year,Letterboxd URI\nStalker,1979,https://letterboxd.com/film/stalker/\n"

    result = Letterboxd.import_watched!(member, StringIO.new(csv), filename: "watched.csv")

    assert_equal 1, result[:read], "the file did have a film in it"
    assert_equal 0, result[:on_file], "but it isn't one they've watched"
  end

  def test_uploading_watchlist_csv_by_mistake_is_caught_by_name
    csv = "Name,Year,Letterboxd URI\nStalker,1979,https://letterboxd.com/film/stalker/\n"

    error = assert_raises(Letterboxd::BadImport) do
      Letterboxd.import_watched!(user, StringIO.new(csv), filename: "watchlist.csv")
    end
    assert_match(/watchlist\.csv/, error.message)
    assert_equal 0, DB[:seen_checks].count
  end

  def test_uploading_the_export_zip_is_caught
    zip = StringIO.new("#{Letterboxd::ZIP_MAGIC}rest of a zip file")

    error = assert_raises(Letterboxd::BadImport) do
      Letterboxd.import_watched!(user, zip, filename: "letterboxd-export.zip")
    end
    assert_match(/[Uu]nzip/, error.message)
  end

  def test_a_file_past_the_cap_is_refused_rather_than_truncated
    body = "Name,Year,Letterboxd URI\n" + ("Stalker,1979,https://letterboxd.com/film/stalker/\n" *
      ((Letterboxd::MAX_IMPORT_BYTES / 45) + 100))

    assert_raises(Letterboxd::BadImport) do
      Letterboxd.import_watched!(user, StringIO.new(body), filename: "watched.csv")
    end
  end

  def test_an_empty_file_says_so
    assert_raises(Letterboxd::BadImport) do
      Letterboxd.import_watched!(user, StringIO.new("Name,Year,Letterboxd URI\n"), filename: "watched.csv")
    end
  end

  def test_choosing_no_file_at_all_says_so
    assert_raises(Letterboxd::BadImport) do
      Letterboxd.import_watched!(user, "", filename: "")
    end
  end

  # A spreadsheet leaves a byte-order mark on the first column name, and CSV
  # then hands back a file with no "Name" column in it.
  def test_a_byte_order_mark_does_not_hide_the_columns
    csv = "\xEF\xBB\xBFName,Year,Letterboxd URI\nStalker,1979,https://letterboxd.com/film/stalker/\n"

    result = Letterboxd.import_watched!(user, StringIO.new(csv), filename: "watched.csv")

    assert_equal 1, result[:read]
  end

  def test_a_title_in_some_other_encoding_costs_one_character_not_the_import
    csv = "Name,Year,Letterboxd URI\nAm\xE9lie,2001,https://letterboxd.com/film/amelie/\n"

    result = Letterboxd.import_watched!(user, StringIO.new(csv), filename: "watched.csv")

    assert_equal 1, result[:read]
    assert_equal "amelie", Film.first(slug: "amelie").slug
  end

  # -- storing ---------------------------------------------------------------

  def test_a_refetched_watchlist_replaces_the_old_one
    member = user
    entries = [{ slug: "a", title: "A", year: 2000 }, { slug: "b", title: "B", year: 2001 }]
    Letterboxd.store!(member, entries)

    Letterboxd.store!(member, [{ slug: "b", title: "B", year: 2001 }])

    assert_equal ["b"], DB[:watchlist_entries].where(user_id: member.id)
                                              .join(:films, id: :film_id).select_map(:slug)
  end

  def test_films_are_shared_rather_than_duplicated_per_member
    a, b = 2.times.map { user }
    entry = [{ slug: "stalker", title: "Stalker", year: 1979 }]

    Letterboxd.store!(a, entry)
    Letterboxd.store!(b, entry)

    assert_equal 1, Film.where(slug: "stalker").count
  end

  def test_a_corrected_title_upstream_is_taken
    member = user
    Letterboxd.store!(member, [{ slug: "stalker", title: "Stalkr", year: 1979 }])
    Letterboxd.store!(member, [{ slug: "stalker", title: "Stalker", year: 1979 }])

    assert_equal "Stalker", Film.first(slug: "stalker").title
  end

  # The bug this was all for: watched.csv carries a boxd.it short link rather
  # than a film path, so the importer invents a slug from the title, and keying
  # films on slug alone gave that film a second row. The seen_checks row landed
  # on it and the club's list entry stayed on the first, so the ballot went on
  # offering a film the member had told us they'd watched.
  def test_an_import_with_no_film_path_finds_the_film_we_already_have
    member = user
    scraped = Film.create(slug: "inception", title: "Inception", year: 2010, created_at: Time.now)
    csv = "Name,Year,Letterboxd URI\nInception,2010,https://boxd.it/1XYZ\n"

    Letterboxd.import_watched!(member, StringIO.new(csv), filename: "watched.csv")

    assert_equal 1, Film.where(title: "Inception").count, "no second row for the same film"
    assert_equal [scraped.id], DB[:seen_checks].where(user_id: member.id).select_map(:film_id)
  end

  # The same collision the other way round: the import came first, so the row
  # carries the slug we made up, and the scrape has to land on it.
  def test_a_scrape_finds_the_row_an_import_invented_and_gives_it_the_real_slug
    member = user
    csv = "Name,Year,Letterboxd URI\nInception,2010,https://boxd.it/1XYZ\n"
    Letterboxd.import_watched!(member, StringIO.new(csv), filename: "watched.csv")
    invented = Film.first(title: "Inception")

    assert_equal "inception-2010", invented.slug, "nothing in the export said otherwise"

    Letterboxd.store_list!(club(mode: "list"), [{ slug: "inception", title: "Inception", year: 2010 }])

    assert_equal 1, Film.where(title: "Inception").count
    assert_equal "inception", invented.refresh.slug, "the real slug wins"
    assert_nil invented.details_fetched_at, "anything fetched under the invented slug was a 404"
  end

  # Letterboxd gives a short and a feature of the same name and year different
  # slugs. Matching on title and year alone would make them one film.
  def test_two_real_slugs_sharing_a_title_and_year_stay_two_films
    Letterboxd.store_list!(club(mode: "list"), [
                             { slug: "the-batman", title: "The Batman", year: 2022 },
                             { slug: "the-batman-1", title: "The Batman", year: 2022 }
                           ])

    assert_equal 2, Film.where(title: "The Batman").count
  end

  # And they still do with an invented row in the way. Both key to it, so
  # whichever slug asks second has to be told no and given a row of its own —
  # otherwise the pair collapses and the list loses one of them for good.
  def test_a_short_and_a_feature_dont_both_adopt_one_invented_row
    member = user
    csv = "Name,Year,Letterboxd URI\nThe Batman,2022,https://boxd.it/1XYZ\n"
    Letterboxd.import_watched!(member, StringIO.new(csv), filename: "watched.csv")

    club = club(mode: "list")
    Letterboxd.store_list!(club, [
                             { slug: "the-batman", title: "The Batman", year: 2022 },
                             { slug: "the-batman-1", title: "The Batman", year: 2022 }
                           ])

    assert_equal %w[the-batman the-batman-1], Film.where(title: "The Batman").order(:slug).select_map(:slug)
    assert_equal 2, DB[:club_list_entries].where(club_id: club.id).count
  end

  # Two entries under one slug are one film whatever their titles say. Resolving
  # them apart put the second in with the films to create and inserted a row for
  # a slug the first was about to adopt — a UNIQUE violation out of an upload.
  def test_one_slug_under_two_titles_is_one_film
    member = user
    csv = "Name,Year,Letterboxd URI\nBrazil,1985,https://boxd.it/1XYZ\n"
    Letterboxd.import_watched!(member, StringIO.new(csv), filename: "watched.csv")

    Letterboxd.store_list!(club(mode: "list"), [
                             { slug: "brazil", title: "Brazil", year: 1985 },
                             { slug: "brazil", title: "Brazil: Director's Cut", year: 1985 }
                           ])

    assert_equal ["brazil"], Film.where(year: 1985).select_map(:slug)
  end

  def test_films_with_no_year_are_never_matched_on_title_alone
    Letterboxd.store_list!(club(mode: "list"), [
                             { slug: "hamlet-a", title: "Hamlet", year: nil },
                             { slug: "hamlet-b", title: "Hamlet", year: nil }
                           ])

    assert_equal 2, Film.where(title: "Hamlet").count
    assert_equal [nil, nil], Film.where(title: "Hamlet").select_map(:match_key)
  end

  def test_a_corrected_title_moves_the_match_key_with_it
    member = user
    Letterboxd.store!(member, [{ slug: "stalker", title: "Stalkr", year: 1979 }])
    Letterboxd.store!(member, [{ slug: "stalker", title: "Stalker", year: 1979 }])

    assert_equal "stalker-1979", Film.first(slug: "stalker").match_key
  end

  def test_a_clubs_list_keeps_the_order_it_was_published_in
    c = club(mode: "list")
    Letterboxd.store_list!(c, %w[c a b].map { |s| { slug: s, title: s.upcase, year: 2000 } })

    ordered = DB[:club_list_entries].where(club_id: c.id).order(:position)
                                    .join(:films, id: :film_id).select_map(:slug)

    assert_equal %w[c a b], ordered
  end

  private

  def poster_page(slugs)
    items = slugs.map do |s|
      %(<div class="react-component" data-item-slug="#{s}" data-item-full-display-name="#{s.upcase} (2000)"></div>)
    end
    "<html><body>#{items.join}</body></html>"
  end
end
