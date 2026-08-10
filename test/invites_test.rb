# Getting people in. There is no public signup — an unauthenticated form that
# emails arbitrary addresses is a spam vector — so this is invites (an admin
# sends one) and sign-in links (a member asks for one).

require_relative "helper"

class InvitesTest < BoxdTest
  def test_an_address_that_is_not_an_address_is_refused
    ["", "   ", "nobody", "no@body", "a@b@c.com", "spaces in@example.com", nil].each do |bad|
      assert_raises(Invites::Invalid, bad.inspect) { Invites.send!(bad) }
    end
    assert_empty deliveries
  end

  def test_an_address_is_normalised_before_anything_else_happens
    Invites.send!("  Someone@Example.COM ")

    assert_equal "someone@example.com", User.first.email
  end

  # -- inviting somebody new -------------------------------------------------

  def test_a_new_address_gets_an_invite_carrying_a_single_use_verify_link
    result = Invites.send!("new@example.com")

    assert_equal :invite, result[:kind]
    assert_equal 1, deliveries.size
    assert_equal "You're invited to Boxd Club", deliveries.first.subject

    raw = result[:url][%r{/verify/([A-Za-z0-9_-]+)}, 1]
    refute_nil Tokens.peek(raw, "verify")
    assert_includes body_of(deliveries.first), result[:url]
  end

  def test_an_invite_into_a_club_says_which_club_and_adds_them_to_it
    c = club(name: "Thursday")

    Invites.send!("new@example.com", club: c)

    member = User.first(email: "new@example.com")
    assert Clubs.member?(c, member)
    assert_equal "You're invited to Thursday", deliveries.first.subject
    # An invite goes to somebody who has never heard of us, so it has to say
    # what a club is before it asks them to join one.
    assert_includes body_of(deliveries.first), c.mode_invite_note
  end

  def test_an_invite_can_make_somebody_an_admin
    Invites.send!("boss@example.com", admin: true)

    assert User.first(email: "boss@example.com").admin
  end

  def test_inviting_the_same_address_twice_does_not_make_a_second_account
    Invites.send!("new@example.com")
    Invites.send!("new@example.com")

    assert_equal 1, User.where(email: "new@example.com").count
  end

  # -- somebody who is already set up ----------------------------------------

  def test_an_established_member_gets_a_sign_in_link_rather_than_a_setup_one
    member = user(email: "old@example.com")

    result = Invites.send!("old@example.com")

    assert_equal :login, result[:kind]
    assert_match %r{/auth/}, result[:url]
    assert_equal "Your Boxd Club sign-in link", deliveries.first.subject
    assert_equal member.id, Tokens.peek(result[:url][%r{/auth/([^?]+)}, 1], "login").user_id
  end

  def test_adding_an_established_member_to_a_club_lands_them_on_the_club_page
    member = user(email: "old@example.com")
    c = club(name: "Thursday")

    result = Invites.send!("old@example.com", club: c)

    assert Clubs.member?(c, member)
    assert_equal "You've been added to Thursday", deliveries.first.subject
    assert_equal c.path, result[:url][/\?to=(.*)\z/, 1]
  end

  def test_a_member_who_never_finished_signing_up_gets_the_setup_link_again
    user(email: "half@example.com", verified_at: nil, active: false)

    assert_equal :invite, Invites.send!("half@example.com")[:kind]
  end

  def test_a_member_with_no_letterboxd_account_yet_gets_the_setup_link
    user(email: "nolb@example.com", username: nil)

    assert_equal :invite, Invites.send!("nolb@example.com")[:kind]
  end

  # -- the /login form -------------------------------------------------------

  # This form is public and says the same thing either way, so it can't be used
  # to test who is a member.
  def test_asking_for_a_link_at_an_unknown_address_sends_nothing
    assert_nil Invites.send_login("nobody@example.com")
    assert_empty deliveries
    assert_equal 0, User.count
  end

  def test_asking_for_a_link_sends_one
    member = user(email: "member@example.com")

    result = Invites.send_login("  MEMBER@example.com ")

    assert_equal member.id, result[:user].id
    assert_equal 1, deliveries.size
  end

  # Unsubscribing means we stop mailing club news, not that they lose the
  # account. This is the only door in, so refusing here would be silence with
  # no explanation and no way back.
  def test_an_unsubscribed_member_can_still_ask_for_a_way_in
    user(email: "gone@example.com", active: false, unsubscribed_at: Time.now)

    refute_nil Invites.send_login("gone@example.com")
    assert_equal 1, deliveries.size
  end

  def test_normalise
    assert_equal "a@b.com", Invites.normalize("  A@B.com  ")
    assert_equal "", Invites.normalize(nil)
  end
end
