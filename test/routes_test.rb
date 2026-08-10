# The app through the front door: real routes, real templates, real session
# cookies. What's checked here is the things a route decides — who may see a
# page, what a POST is allowed to do, and what a hand-made request can't.

require_relative "helper"

class RoutesTest < BoxdTest
  include Rack::Test::Methods

  def app = App

  def setup
    super
    @member, @other = 2.times.map { user }
    @club = club(name: "Thursday", members: [@member, @other], ballot_size: 3)
    films(4).each { |f| watchlist(@member, [f]); watchlist(@other, [f]) }
  end

  # -- healthcheck -----------------------------------------------------------

  # A container that boots fine and has no schema is exactly the state this has
  # to fail on, which an empty-bodied check would call healthy.
  def test_the_healthcheck_touches_the_database
    get "/up"
    assert_equal 200, last_response.status
    assert_equal "ok", last_response.body

    # The failure this has to catch is a container that boots fine and has no
    # schema, which an empty-bodied check would call healthy.
    DB.rename_table(:schema_info, :schema_info_moved)
    begin
      get "/up"
      refute_equal "ok", last_response.body, "a schema-less database isn't healthy"
    ensure
      DB.rename_table(:schema_info_moved, :schema_info)
    end
  end

  # -- signing in ------------------------------------------------------------

  def test_the_front_page_is_the_sign_in_form_until_you_are_signed_in
    get "/"
    assert_equal 200, last_response.status
    assert_includes last_response.body, "Email me a link"

    sign_in(@member)
    get "/"
    assert_includes last_response.body, "Thursday"
  end

  def test_a_magic_link_signs_you_in_and_lands_where_the_email_meant
    get URI.parse(Tokens.login_url(@member, @club.path)).request_uri

    assert_equal 302, last_response.status
    assert_equal @club.path, URI.parse(last_response.location).path
    follow_redirect!
    assert_equal 200, last_response.status
  end

  def test_a_link_that_was_never_ours_signs_nobody_in
    get "/auth/not-a-real-token"

    assert_equal 200, last_response.status
    assert_includes last_response.body, "expired"
    get "/"
    assert_includes last_response.body, "Email me a link"
  end

  # A ?to= that leaves the site is the open-redirect this has to refuse.
  def test_a_link_can_only_land_you_on_this_site
    ["//evil.com", "https://evil.com", "/\\evil.com"].each do |target|
      get "#{URI.parse(Tokens.login_url(@member)).path}?to=#{CGI.escape(target)}"

      assert_equal "/", last_response.location, target
    end
  end

  def test_asking_for_a_sign_in_link_says_the_same_thing_whoever_you_are
    known = post_form("/login", "/login", email: @member.email).body
    unknown = post_form("/login", "/login", email: "nobody@example.com").body
    # Every page carries a random film quote, which is the only thing allowed
    # to differ between these two.
    without_quote = ->(body) { body.sub(%r{<blockquote.*?</blockquote>}m, "") }

    assert_includes known, "Check your email"
    assert_equal without_quote[known], without_quote[unknown]
    assert_equal 1, deliveries.size, "only the address we know gets mail"
  end

  # Both allowances are spent whatever the address turns out to be — checking
  # the user first would make an unknown address cheaper than a real one.
  def test_asking_over_and_over_is_refused
    limit = Throttle::LIMITS[:login_email][:limit]
    limit.times { post_form("/login", "/login", email: @member.email) }

    response = post_form("/login", "/login", email: @member.email)

    assert_equal 429, response.status
    assert_includes response.body, "an hour"
    assert_equal limit, deliveries.size
  end

  def test_signing_out_ends_the_session
    sign_in(@member)

    post "/logout", "_csrf" => csrf_for("/", "/logout")

    get "/"
    assert_includes last_response.body, "Email me a link"
  end

  # -- who may see a club ----------------------------------------------------

  def test_a_club_that_does_not_exist_is_a_404
    sign_in(@member)

    get "/club/no-such-club"

    assert_equal 404, last_response.status
  end

  def test_a_signed_out_visitor_is_sent_to_sign_in
    get @club.path

    assert_equal 302, last_response.status
    assert_equal "/login", URI.parse(last_response.location).path
  end

  def test_somebody_elses_club_is_not_yours_to_look_at
    sign_in(user)

    get @club.path

    assert_equal 403, last_response.status
  end

  def test_an_admin_can_look_at_any_club
    sign_in(user(admin: true))

    get @club.path

    assert_equal 200, last_response.status
  end

  def test_the_old_club_url_still_works
    get "/c/#{@club.slug}"

    assert_equal 301, last_response.status
    assert_equal @club.path, URI.parse(last_response.location).path
  end

  def test_a_past_round_has_a_permalink_by_its_number
    sign_in(@member)
    film = Film.first
    past = round(@club, [film], state: "watched", winning_film_id: film.id)

    get "#{@club.path}/round/#{past.number}"

    assert_equal 200, last_response.status
    assert_includes last_response.body, film.title

    get "#{@club.path}/round/99"
    assert_equal 404, last_response.status
  end

  # -- voting ----------------------------------------------------------------

  def test_a_ballot_is_recorded_and_the_page_says_so
    round = Rounds.open!(@club)
    sign_in(@member)

    response = post_ballot(round, round.candidates)

    assert_equal 302, last_response.status
    assert_equal({ round.candidates[0].id => 1, round.candidates[1].id => 2,
                   round.candidates[2].id => 3 }, Votes.ranking_for(round, @member))
    follow_redirect!
    assert_includes last_response.body, "Ballot submitted"
    assert response
  end

  # Mail scanners prefetch every URL in a message, and would otherwise cast
  # ballots nobody intended.
  def test_a_ballot_cannot_be_cast_by_following_a_link
    round = Rounds.open!(@club)
    sign_in(@member)

    get "#{@club.path}/vote"

    assert_equal 404, last_response.status
    refute Votes.voted?(round, @member)
  end

  # The realistic failure here isn't an attack, it's a days-old page in a
  # browser that dropped the session cookie.
  def test_a_form_posted_without_its_token_says_so_rather_than_crashing
    round = Rounds.open!(@club)
    sign_in(@member)

    post "#{@club.path}/vote", "rank" => { round.candidates.first.id.to_s => "1" }

    assert_equal 403, last_response.status
    assert_includes last_response.body, "That form expired."
    refute Votes.voted?(round, @member)
  end

  def test_a_ballot_that_is_not_a_ballot_is_a_message_not_a_500
    round = Rounds.open!(@club)
    sign_in(@member)
    token = csrf_for(@club.path, "#{@club.path}/vote")

    # Every film given the same position.
    post "#{@club.path}/vote", "_csrf" => token,
                               "rank" => round.candidates.to_h { |c| [c.id.to_s, "1"] }

    assert_equal 200, last_response.status
    assert_includes last_response.body, "distinct position"
    refute Votes.voted?(round, @member)
  end

  # A hand-made request can put anything under `rank` — a bare string, or
  # nested hashes.
  def test_a_hand_made_ballot_of_the_wrong_shape_does_not_crash
    round = Rounds.open!(@club)
    sign_in(@member)
    token = csrf_for(@club.path, "#{@club.path}/vote")

    [{ "rank" => "nonsense" },
     { "rank" => { "not-an-id" => "not-a-rank" } },
     {}].each do |params|
      post "#{@club.path}/vote", { "_csrf" => token }.merge(params)

      assert_includes [200, 302], last_response.status, params.inspect
      refute Votes.voted?(round, @member)
    end
  end

  def test_the_last_ballot_in_decides_the_round_from_the_page
    round = Rounds.open!(@club)
    Votes.record_ranking!(round, @other,
                          round.candidates.each_with_index.to_h { |c, i| [c.id, i + 1] })
    sign_in(@member)

    post_ballot(round, round.candidates)

    assert_equal "decided", round.refresh.state
  end

  # -- skipping --------------------------------------------------------------

  def test_a_skip_vote_is_recorded_and_reported
    round = decided_round
    sign_in(@member)

    post "#{@club.path}/skip", "_csrf" => csrf_for(@club.path, "#{@club.path}/skip")

    assert_equal "decided", round.refresh.state
    follow_redirect!
    assert_includes last_response.body, "1 more to skip it"
  end

  # While a ballot is open the way out is to rank it, so the club page doesn't
  # offer the skip at all — there's no form to take a token from, which is why
  # this checks the page rather than posting to it.
  def test_there_is_nothing_to_skip_while_a_ballot_is_open
    Rounds.open!(@club)
    sign_in(@member)

    get @club.path

    assert_equal 200, last_response.status
    refute_includes last_response.body, "Vote to skip"
  end

  # -- avatars ---------------------------------------------------------------

  def test_the_avatar_route_only_serves_files_it_wrote
    FileUtils.mkdir_p(Avatars::DIR)
    name = "#{@member.id}-abcdef01.jpg"
    File.binwrite(File.join(Avatars::DIR, name), "JPEGBYTES")

    get "/avatars/#{name}"

    assert_equal 200, last_response.status
    assert_equal "JPEGBYTES", last_response.body
    assert_equal "image/jpeg", last_response["Content-Type"]
    assert_includes last_response["Cache-Control"], "immutable"
  end

  def test_the_avatar_route_cannot_be_talked_up_out_of_its_directory
    ["..%2F..%2Fboxd.db", "..%2Fboxd.db", "1-abcdef01.svg", "boxd.db"].each do |name|
      get "/avatars/#{name}"

      assert_equal 404, last_response.status, name
    end
  end

  # -- unsubscribing ---------------------------------------------------------

  # RFC 8058 one-click: the mail client POSTs straight here with no page to
  # have taken a CSRF token from. The unguessable token in the path is the
  # capability, and Gmail holds a failing unsubscribe against the domain.
  def test_a_one_click_unsubscribe_needs_no_csrf_token
    raw = Tokens.issue(@member, "unsub")

    post "/unsubscribe/#{raw}", "List-Unsubscribe" => "One-Click"

    assert_equal 200, last_response.status
    @member.refresh
    refute @member.active
    refute_nil @member.unsubscribed_at
    assert_nil Tokens.peek(raw, "unsub"), "the token is single-use"
  end

  def test_the_on_page_unsubscribe_form_still_carries_its_token
    raw = Tokens.issue(@member, "unsub")

    get "/unsubscribe/#{raw}"
    assert_equal 200, last_response.status

    post "/unsubscribe/#{raw}"
    assert_equal 403, last_response.status
    assert @member.refresh.active
  end

  def test_an_unsubscribe_link_that_has_been_used_says_so
    raw = Tokens.issue(@member, "unsub")
    Tokens.consume(raw, "unsub")

    get "/unsubscribe/#{raw}"

    assert_includes last_response.body, "expired"
  end

  # Signing in must never quietly re-subscribe somebody who unsubscribed.
  def test_signing_in_does_not_put_an_unsubscribed_member_back_on_the_list
    @member.update(active: false, unsubscribed_at: Time.now)

    sign_in(@member)

    @member.refresh
    refute @member.active
    refute_nil @member.unsubscribed_at
  end

  # -- joining ---------------------------------------------------------------

  def test_an_invited_member_confirms_their_address_and_names_their_account
    invited = user(email: "new@example.com", username: nil, verified_at: nil, active: false)
    raw = Tokens.issue(invited, "verify")

    get "/verify/#{raw}"
    assert_equal 200, last_response.status
    token = last_response.body[/name="_csrf" value="([^"]+)"/, 1]

    stub_method(Letterboxd, :check, ->(_username) { 42 }) do
      post "/profile/#{raw}", "_csrf" => token, "letterboxd_username" => "newperson"
    end

    invited.refresh
    assert_equal "newperson", invited.letterboxd_username
    assert invited.active
    refute_nil invited.verified_at
    assert_nil Tokens.peek(raw, "verify"), "the invite is used up once the name is saved"
  end

  # A prefetched link must not burn the invite.
  def test_opening_the_invite_without_finishing_it_does_not_use_it_up
    invited = user(email: "new@example.com", username: nil, verified_at: nil, active: false)
    raw = Tokens.issue(invited, "verify")

    get "/verify/#{raw}"

    refute_nil Tokens.peek(raw, "verify")
  end

  def test_a_username_someone_else_here_already_uses_is_refused
    invited = user(email: "new@example.com", username: nil, verified_at: nil, active: false)
    raw = Tokens.issue(invited, "verify")
    get "/verify/#{raw}"
    token = last_response.body[/name="_csrf" value="([^"]+)"/, 1]

    post "/profile/#{raw}", "_csrf" => token,
                            "letterboxd_username" => @member.letterboxd_username

    assert_includes last_response.body, "already using that Letterboxd account"
    assert_nil invited.refresh.letterboxd_username
  end

  # -- settings --------------------------------------------------------------

  def test_settings_needs_you_to_be_signed_in
    get "/settings"

    assert_equal "/login", URI.parse(last_response.location).path
  end

  # What we hold belongs to the old account: a stranger's watch history would
  # quietly suppress films nobody has watched.
  def test_relinking_to_another_account_throws_away_what_we_held
    sign_in(@member)
    Seen.record!(user_id: @member.id, film_id: Film.first.id, seen: true)
    @member.update(watched_imported_at: Time.now)

    stub_method(Letterboxd, :check, ->(_username) { 42 }) do
      stub_method(Letterboxd, :refresh_user!, ->(*, **) { nil }) do
        stub_method(Avatars, :refresh!, ->(*, **) { nil }) do
          post "/settings", "_csrf" => csrf_for("/settings", "/settings"),
                            "letterboxd_username" => "somebodyelse"
        end
      end
    end

    @member.refresh
    assert_equal "somebodyelse", @member.letterboxd_username
    assert_equal 0, DB[:watchlist_entries].where(user_id: @member.id).count
    assert_equal 0, DB[:seen_checks].where(user_id: @member.id).count
    assert_nil @member.watched_imported_at
  end

  # People paste the whole profile URL as often as they type the name.
  def test_a_pasted_profile_url_is_taken_as_a_username
    sign_in(@member)

    stub_method(Letterboxd, :check, ->(username) { username == "dave" ? 42 : flunk("got #{username}") }) do
      stub_method(Letterboxd, :refresh_user!, ->(*, **) { nil }) do
        stub_method(Avatars, :refresh!, ->(*, **) { nil }) do
          post "/settings", "_csrf" => csrf_for("/settings", "/settings"),
                            "letterboxd_username" => "https://letterboxd.com/dave/films/"
        end
      end
    end

    assert_equal "dave", @member.refresh.letterboxd_username
  end

  # -- admin -----------------------------------------------------------------

  def test_the_admin_area_is_not_open_to_members
    sign_in(@member)

    get "/admin"

    assert_equal 403, last_response.status
  end

  def test_an_admin_can_see_it
    sign_in(user(admin: true))

    get "/admin"

    assert_equal 200, last_response.status
  end

  def test_an_admin_can_create_a_club
    sign_in(user(admin: true))

    post "/admin/clubs", "_csrf" => csrf_for("/admin", "/admin/clubs"),
                         "name" => "Sunday Matinee", "list_mode" => "own", "ballot_size" => "4"

    club = Club.first(slug: "sunday-matinee")
    refute_nil club
    assert_equal 4, club.ballot_size
  end

  def test_a_bad_club_form_comes_back_as_a_message
    sign_in(user(admin: true))

    post "/admin/clubs", "_csrf" => csrf_for("/admin", "/admin/clubs"),
                         "name" => "", "list_mode" => "own"

    assert_equal 302, last_response.status
    follow_redirect!
    assert_includes last_response.body, "A club needs a name."
  end

  # A borrowed admin session shouldn't be able to mail a list.
  def test_invites_are_rate_limited_too
    sign_in(user(admin: true))
    token = csrf_for("/admin", "/admin/invite")
    limit = Throttle::LIMITS[:invite_ip][:limit]

    limit.times { |i| post "/admin/invite", "_csrf" => token, "email" => "p#{i}@example.com" }
    post "/admin/invite", "_csrf" => token, "email" => "last@example.com"

    assert_equal 429, last_response.status
    assert_nil User.first(email: "last@example.com")
  end

  # -- development-only routes -----------------------------------------------

  def test_the_email_previews_are_not_served_outside_development
    sign_in(user(admin: true))

    get "/dev/emails"

    assert_equal 404, last_response.status
  end

  private

  def post_form(page, action, **params)
    post action, { "_csrf" => csrf_for(page, action) }.merge(params.transform_keys(&:to_s))
    last_response
  end

  def post_ballot(round, candidates)
    post "#{@club.path}/vote",
         "_csrf" => csrf_for(@club.path, "#{@club.path}/vote"),
         "rank" => candidates.each_with_index.to_h { |c, i| [c.id.to_s, (i + 1).to_s] }
  end

  def decided_round
    round = Rounds.open!(@club)
    ranking = round.candidates.each_with_index.to_h { |c, i| [c.id, i + 1] }
    Votes.record_ranking!(round, @member, ranking)
    Votes.record_ranking!(round, @other, ranking)
    Rounds.check_after_vote!(round)
    deliveries.clear
    round.refresh
  end
end
