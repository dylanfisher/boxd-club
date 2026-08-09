# Magic links are the entire auth model. There is no password anywhere.
#
# Only the SHA256 of a token is stored, so a database leak doesn't hand over
# working links. The raw token exists exactly once, in the email we send.
#
# Three purposes:
#   verify  single-use, from an invite. Captures a Letterboxd username.
#   login   signs the member in and lands them somewhere. Reusable until it
#           expires, so an old ballot email still works next week.
#   unsub   single-use, minted fresh per email.

require "securerandom"
require "digest"

require_relative "models"

module Tokens
  VERIFY_TTL = 14 * 86_400
  LOGIN_TTL  = 60 * 86_400
  UNSUB_TTL  = 365 * 86_400

  module_function

  # Returns the raw token. This is the only time it exists in plaintext.
  def issue(user, purpose, expires_at: nil)
    raw = SecureRandom.urlsafe_base64(32)
    Token.create(
      user_id: user.id,
      purpose: purpose,
      token_hash: hash(raw),
      expires_at: expires_at || default_expiry(purpose),
      created_at: Time.now
    )
    raw
  end

  # Looks up a token without consuming it. Returns nil if missing, expired, or
  # already used. Lookup is by hash of an unguessable 256-bit value, so there is
  # no timing oracle worth closing here.
  def peek(raw, purpose)
    return nil if raw.to_s.empty?

    token = Token.first(token_hash: hash(raw), purpose: purpose)
    return nil if token.nil? || token.used? || token.expired?

    token
  end

  # Single-use tokens ('verify', 'unsub') go through here. Login tokens don't —
  # they stay usable until they expire, because the same email gets reopened.
  def consume(raw, purpose)
    token = peek(raw, purpose)
    return nil unless token

    token.update(used_at: Time.now)
    token
  end

  # Development only. A sign-in link whose token is a known, fixed string, so
  # the four demo accounts have links that can be written down — in the README,
  # in a bookmark — and still work tomorrow. `issue` is deliberately
  # unguessable; this is deliberately guessable, which is exactly why it refuses
  # to run outside development. Re-seeding renews the same link rather than
  # piling up tokens.
  #
  # The blast radius even if this did somehow run elsewhere is the fixture
  # accounts it's called for, but the guard means the question doesn't arise.
  def dev_login_url(user, to, label)
    raise "dev_login_url is development-only (APP_ENV=#{APP_ENV})" unless APP_ENV == "development"

    raw = "dev-#{label}"
    Token.where(token_hash: hash(raw)).delete
    Token.create(
      user_id: user.id,
      purpose: "login",
      token_hash: hash(raw),
      expires_at: Time.now + LOGIN_TTL,
      created_at: Time.now
    )
    "#{url('/auth', raw)}?to=#{encode(to)}"
  end

  def url(path, raw) = "#{BASE_URL}#{path}/#{raw}"

  # A sign-in link that lands on `to` (a path on this site).
  def login_url(user, to = "/")
    "#{url('/auth', issue(user, 'login'))}?to=#{encode(to)}"
  end

  def encode(str) = str.to_s.gsub(/[^A-Za-z0-9\-._~\/]/) { |c| format("%%%02X", c.ord) }

  # Only ever redirect to a path on this site — never to whatever a query
  # string asks for.
  #
  # One leading slash and no second one: "//evil.com" is a protocol-relative
  # URL, and several browsers normalise the backslash in "/\evil.com" to a
  # slash and treat it as exactly the same thing. Both leave the site.
  def safe_path(to, fallback: "/")
    to = to.to_s
    to.match?(%r{\A/(?![/\\])}) ? to : fallback
  end

  # Drops tokens that expired over a week ago. Keeping them briefly past expiry
  # means a late click gets "this link expired" rather than a bare 404.
  def cleanup!
    cutoff = Time.now - (7 * 86_400)
    n = Token.where { expires_at < cutoff }.delete
    puts "[cleanup] removed #{n} expired tokens"
    n
  end

  def hash(raw) = Digest::SHA256.hexdigest(raw)

  def default_expiry(purpose)
    case purpose
    when "verify" then Time.now + VERIFY_TTL
    when "login"  then Time.now + LOGIN_TTL
    when "unsub"  then Time.now + UNSUB_TTL
    end
  end
end
