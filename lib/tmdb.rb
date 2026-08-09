# Poster and backdrop art. Letterboxd film pages give us a TMDB id; TMDB gives
# us the image paths; the images themselves are hotlinked from image.tmdb.org,
# so we store nothing but URLs.
#
# TMDB_API_KEY is optional. Without it we fall back to the poster and backdrop
# on the Letterboxd film page (a.ltrbxd.com serves those without a challenge),
# so the art still works — it's just Letterboxd's crops rather than TMDB's.

require "net/http"
require "uri"
require "json"

module TMDB
  API = "https://api.themoviedb.org/3"
  IMAGE_BASE = "https://image.tmdb.org/t/p"
  # w342 is the smallest poster that still looks right on a 2x phone screen.
  POSTER_SIZE = "w342"
  # The backdrop spans the page, so it wants a wide source. w1280 is TMDB's
  # last step before the full-size original.
  BACKDROP_SIZE = "w1280"

  module_function

  def key = ENV["TMDB_API_KEY"].to_s

  def configured? = !key.empty?

  # Hotlinkable poster and backdrop URLs for one film, either of which may be
  # nil. One request for both — they come from the same movie record.
  def art(tmdb_id)
    return {} if tmdb_id.nil? || !configured?

    movie = movie(tmdb_id) or return {}
    {
      poster_url: image(movie["poster_path"], POSTER_SIZE),
      backdrop_url: image(movie["backdrop_path"], BACKDROP_SIZE)
    }.compact
  rescue StandardError => e
    warn "[tmdb] #{tmdb_id}: #{e.class}: #{e.message}"
    {}
  end

  def image(path, size)
    path.to_s.empty? ? nil : "#{IMAGE_BASE}/#{size}#{path}"
  end

  def movie(tmdb_id)
    uri = URI("#{API}/movie/#{tmdb_id}?api_key=#{URI.encode_www_form_component(key)}")
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                                              open_timeout: 10, read_timeout: 15) do |http|
      http.request(Net::HTTP::Get.new(uri))
    end
    return nil unless res.is_a?(Net::HTTPSuccess)

    JSON.parse(res.body.to_s)
  end
end
