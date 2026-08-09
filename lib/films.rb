# Film metadata: director, Letterboxd rating, poster.
#
# Watchlist scraping only yields a slug, title and year, and there can be
# hundreds of those per member. Fetching a film page each would be a crawl, so
# details are filled in lazily — for the handful of films that actually reach a
# ballot, right before the ballot goes out.

require_relative "models"
require_relative "letterboxd"
require_relative "tmdb"

module Films
  # Ratings drift and posters get replaced; refresh anything older than this
  # when we happen to touch it again.
  REFRESH_AFTER = 90 * 86_400

  module_function

  # Fills in details for a film unless they're already fresh. Returns the film.
  def enrich!(film, force: false)
    return film unless force || stale?(film)

    details = Letterboxd.film_details(film.slug)
    # TMDB's crops win when there's a key; Letterboxd's are the fallback.
    art = TMDB.art(details[:tmdb_id])

    film.update(
      director: details[:director] || film.director,
      rating: details[:rating] || film.rating,
      tmdb_id: details[:tmdb_id] || film.tmdb_id,
      poster_url: art[:poster_url] || details[:poster_url] || film.poster_url,
      backdrop_url: art[:backdrop_url] || details[:backdrop_url] || film.backdrop_url,
      details_fetched_at: Time.now
    )
    film
  rescue *Letterboxd::TRANSPORT_ERRORS => e
    # A missing director is cosmetic. Never let it stop a round opening.
    warn "[films] #{film.slug}: #{e.class}: #{e.message}"
    film
  end

  # pace: :interactive by default — the caller is usually a ballot about to go
  # out, and it's only ballot_size film pages. A bulk backfill should pass
  # :background.
  def enrich_all!(films, force: false, pace: :interactive)
    fetched = 0
    films.each do |film|
      next unless force || stale?(film)

      Letterboxd.pause(Letterboxd::PACE.fetch(pace)) if fetched.positive?
      enrich!(film, force: force)
      fetched += 1
    end
    films
  end

  def stale?(film)
    film.details_fetched_at.nil? || film.details_fetched_at < Time.now - REFRESH_AFTER
  end
end
