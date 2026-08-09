# Members' profile pictures, taken from their Letterboxd account.
#
# Two cases, and they're handled differently on purpose:
#
#   a.ltrbxd.com  Letterboxd's own upload. We download the bytes once and serve
#                 them from /avatars/<file> ourselves. Letterboxd is a small
#                 site doing us a favour — putting an image request on every
#                 club page view is exactly the sort of traffic not to send
#                 them, and a copy also survives the account being deleted.
#
#   gravatar.com  A public avatar CDN built for hotlinking, and the same image
#                 the member already serves everywhere else on the web. Nothing
#                 to copy: store the URL and link it.
#
# Files live next to the database rather than under a public/ directory,
# because the database directory is the one thing mounted as a volume — an
# avatar written into the image would vanish on the next deploy.

require "digest"
require "fileutils"
require "net/http"
require "uri"

require_relative "models"
require_relative "letterboxd"

module Avatars
  DIR = ENV["AVATAR_DIR"] || File.join(APP_ROOT, "db", "avatars")

  # Faces change less often than watchlists. Re-checking monthly is enough, and
  # it's one request per member on top of a nightly job that already makes
  # dozens.
  REFRESH_AFTER = 30 * 86_400

  # An avatar is ~10KB at 220px. Anything an order of magnitude past that isn't
  # an avatar, and we stop reading rather than find out what it is.
  MAX_BYTES = 2 << 20

  # Only what a.ltrbxd.com actually serves. The extension is echoed back in the
  # filename and the Content-Type, so it can't be attacker-chosen.
  TYPES = { ".jpg" => "image/jpeg", ".jpeg" => "image/jpeg",
            ".png" => "image/png", ".gif" => "image/gif" }.freeze

  # Filenames we generate: <user id>-<8 hex>.<ext>. Anything else asking to be
  # served is refused, so the route can't be talked up out of DIR.
  SAFE_NAME = /\A\d+-[0-9a-f]{8}\.(jpg|jpeg|png|gif)\z/

  module_function

  def stale?(user)
    return false unless user.linked?

    user.avatar_fetched_at.nil? || user.avatar_fetched_at < Time.now - REFRESH_AFTER
  end

  # Looks up this member's Letterboxd avatar and stores it — the bytes for a
  # Letterboxd upload, the URL for a Gravatar. Records the attempt either way,
  # so an account with no picture isn't re-checked every night.
  #
  # Never raises: an avatar is decoration, and this runs unattended.
  def refresh!(user, force: false)
    return nil unless user.linked?
    return nil unless force || stale?(user)

    src = Letterboxd.avatar(user.letterboxd_username)
    return clear!(user) if src.nil?

    if gravatar?(src)
      user.update(avatar_url: gravatar_size(src), avatar_file: nil, avatar_fetched_at: Time.now)
    else
      file = download(user, src) or return clear!(user)
      remove_file(user.avatar_file) unless user.avatar_file == file
      user.update(avatar_url: nil, avatar_file: file, avatar_fetched_at: Time.now)
    end
    user
  rescue Letterboxd::Error, SocketError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout => e
    warn "[avatar] #{user.letterboxd_username}: #{e.class}: #{e.message}"
    nil
  end

  # Everyone who could use a fresh picture. Paced like the watchlist crawl,
  # because it's the same site.
  def refresh_all!(pace: :background, force: false)
    users = User.reachable.exclude(letterboxd_username: nil).all
    users = users.select { |u| stale?(u) } unless force
    return 0 if users.empty?

    users.shuffle.each_with_index do |user, i|
      Letterboxd.pause(Letterboxd::PACE.fetch(pace)) if i.positive?
      refresh!(user, force: force)
    end
    users.size
  end

  def gravatar?(url) = URI(url).host.to_s.end_with?("gravatar.com")

  # Letterboxd asks Gravatar for 48px, which is a blur at 2x. Gravatar sizes on
  # a query parameter, so ask it for the same size we take from Letterboxd.
  def gravatar_size(url) = url.sub(/([?&]s(?:ize)?=)\d+/, "\\1#{Letterboxd::AVATAR_SIZE}")

  # Returns the stored filename, or nil if the fetch gave us something that
  # isn't a usable image.
  def download(user, url)
    uri = URI(url)
    ext = TYPES.key?(File.extname(uri.path).downcase) ? File.extname(uri.path).downcase : ".jpg"
    body = fetch(uri) or return nil
    return nil if body.empty?

    FileUtils.mkdir_p(DIR)
    # The digest is of the URL, not the bytes: Letterboxd's avatar URLs carry a
    # ?v= cache buster that changes when the picture does, so a new picture
    # lands on a new filename and no browser serves the old one from cache.
    name = "#{user.id}-#{Digest::SHA256.hexdigest(url)[0, 8]}#{ext}"
    File.binwrite(File.join(DIR, name), body)
    name
  end

  def fetch(uri)
    req = Net::HTTP::Get.new(uri)
    req["User-Agent"] = Letterboxd::USER_AGENT
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                              open_timeout: 10, read_timeout: 20) do |http|
      http.request(req)
    end
    return nil unless res.is_a?(Net::HTTPSuccess)
    return nil unless res["Content-Type"].to_s.start_with?("image/")

    res.body.to_s.byteslice(0, MAX_BYTES)
  end

  # No picture on the account (or one we can't use). Record the check so it
  # isn't repeated nightly, and drop whatever we were holding.
  def clear!(user)
    remove_file(user.avatar_file)
    user.update(avatar_url: nil, avatar_file: nil, avatar_fetched_at: Time.now)
    nil
  end

  def remove_file(name)
    return if name.to_s.empty? || !SAFE_NAME.match?(name)

    FileUtils.rm_f(File.join(DIR, name))
  end

  # Absolute path for a name the browser asked for, or nil. The name must be one
  # we could have generated and must resolve inside DIR — this is the one place
  # a request parameter reaches the filesystem.
  def path_for(name)
    return nil unless SAFE_NAME.match?(name.to_s)

    path = File.join(DIR, name)
    File.file?(path) ? path : nil
  end

  def content_type(name) = TYPES.fetch(File.extname(name).downcase, "application/octet-stream")
end
