# Magic links are the entire auth model. There is no password anywhere, so a
# token that outlives its purpose, or a redirect that leaves the site, is the
# whole security surface.

require_relative "helper"

class TokensTest < BoxdTest
  def setup
    super
    @user = user
  end

  def test_only_the_hash_of_a_token_is_stored
    raw = Tokens.issue(@user, "login")

    assert_equal 1, Token.count
    refute_equal raw, Token.first.token_hash
    assert_equal Digest::SHA256.hexdigest(raw), Token.first.token_hash
    assert_nil Token.where(Sequel.like(:token_hash, "%#{raw}%")).first
  end

  def test_a_token_is_only_good_for_the_purpose_it_was_issued_for
    raw = Tokens.issue(@user, "verify")

    refute_nil Tokens.peek(raw, "verify")
    assert_nil Tokens.peek(raw, "login")
    assert_nil Tokens.peek(raw, "unsub")
  end

  def test_a_made_up_token_is_refused
    Tokens.issue(@user, "login")

    assert_nil Tokens.peek("not-a-real-token", "login")
    assert_nil Tokens.peek("", "login")
    assert_nil Tokens.peek(nil, "login")
  end

  def test_an_expired_token_is_refused
    raw = Tokens.issue(@user, "login", expires_at: Time.now - 1)

    assert_nil Tokens.peek(raw, "login")
  end

  def test_consuming_a_token_uses_it_up
    raw = Tokens.issue(@user, "verify")

    refute_nil Tokens.consume(raw, "verify")
    assert_nil Tokens.consume(raw, "verify")
    assert_nil Tokens.peek(raw, "verify")
  end

  # An emailed ballot gets reopened days later, so a sign-in link has to keep
  # working until it expires.
  def test_a_sign_in_link_stays_usable
    raw = Tokens.issue(@user, "login")

    3.times { refute_nil Tokens.peek(raw, "login"), "a login token isn't single-use" }
  end

  def test_a_sign_in_link_lands_where_it_was_told_to
    url = Tokens.login_url(@user, "/club/thursday")

    assert url.start_with?("#{BASE_URL}/auth/"), "expected an absolute link, got #{url}"
    assert_equal "/club/thursday", url[/\?to=(.*)\z/, 1]
    assert_equal @user.id, Tokens.peek(url[%r{/auth/([^?]+)}, 1], "login").user_id
  end

  def test_the_default_lifetimes_are_the_documented_ones
    {
      "verify" => Tokens::VERIFY_TTL,
      "login" => Tokens::LOGIN_TTL,
      "unsub" => Tokens::UNSUB_TTL
    }.each do |purpose, ttl|
      Tokens.issue(@user, purpose)
      assert_in_delta Time.now + ttl, Token.order(:id).last.expires_at, 5, purpose
    end
  end

  # -- where a link may send you ---------------------------------------------

  def test_a_redirect_only_ever_goes_to_a_path_on_this_site
    {
      "/club/thursday" => "/club/thursday",
      "/" => "/",
      # Protocol-relative — leaves the site.
      "//evil.com" => "/",
      # Several browsers normalise the backslash to a slash and treat this as
      # exactly the same thing.
      "/\\evil.com" => "/",
      "https://evil.com" => "/",
      "http://evil.com" => "/",
      "javascript:alert(1)" => "/",
      "evil.com" => "/",
      "" => "/",
      nil => "/"
    }.each do |given, expected|
      assert_equal expected, Tokens.safe_path(given), given.inspect
    end
  end

  def test_a_refused_redirect_can_be_given_somewhere_else_to_go
    assert_equal "/settings", Tokens.safe_path("//evil.com", fallback: "/settings")
  end

  def test_a_path_is_escaped_without_losing_its_slashes
    assert_equal "/club/a-b", Tokens.encode("/club/a-b")
    assert_equal "/club/a%20b", Tokens.encode("/club/a b")
    assert_equal "%3Cscript%3E", Tokens.encode("<script>")
  end

  # -- housekeeping ----------------------------------------------------------

  # Keeping them briefly past expiry means a late click gets "this link
  # expired" rather than a bare 404.
  def test_cleanup_drops_long_dead_tokens_and_keeps_the_recently_expired
    Tokens.issue(@user, "login", expires_at: Time.now - (8 * 86_400))
    just_expired = Tokens.issue(@user, "login", expires_at: Time.now - 60)
    live = Tokens.issue(@user, "login")

    assert_equal 1, Tokens.cleanup!
    assert_equal 2, Token.count
    refute_nil Token.first(token_hash: Tokens.hash(just_expired))
    refute_nil Tokens.peek(live, "login")
  end

  # It mints a link whose token is a known, fixed string. That is exactly why
  # it refuses to run anywhere but development.
  def test_the_guessable_development_link_refuses_to_run_outside_development
    assert_equal "test", APP_ENV

    error = assert_raises(RuntimeError) { Tokens.dev_login_url(@user, "/", "demo") }

    assert_match(/development-only/, error.message)
    assert_equal 0, Token.count
  end
end
