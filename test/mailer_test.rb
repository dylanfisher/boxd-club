# Outbound mail. Mailer.deliver is the one choke point for every message this
# app sends, and the check it makes — that the address belongs to the user
# row — is what stops any form that takes an email being a way to mail a
# stranger from this server.

require_relative "helper"

class MailerTest < BoxdTest
  def setup
    super
    @user = user(email: "member@example.com")
  end

  def deliver(to: @user.email, user: @user, subject: "Hello", template: "login", **locals)
    Mailer.deliver(to: to, user: user, subject: subject, template: template,
                   club: nil, login_url: "#{BASE_URL}/auth/x?to=/", **locals)
  end

  # -- who may be mailed -----------------------------------------------------

  def test_a_message_only_ever_goes_to_the_users_own_address
    error = assert_raises(Mailer::Unknown) { deliver(to: "stranger@example.com") }

    assert_match(/isn't user #{@user.id}'s address/, error.message)
    assert_empty deliveries
  end

  def test_the_address_is_matched_however_it_was_typed
    deliver(to: "  MEMBER@Example.COM  ")

    assert_equal 1, deliveries.size
  end

  # A User built but never saved, at an address that does exist — so the only
  # thing standing between it and a send is the missing id.
  def test_a_user_who_was_never_saved_cannot_be_mailed
    assert_raises(Mailer::Unknown) do
      deliver(user: User.new(email: @user.email))
    end
    assert_empty deliveries
  end

  def test_a_user_deleted_since_they_were_loaded_cannot_be_mailed
    loaded = @user
    User.where(id: @user.id).delete

    assert_raises(Mailer::Unknown) { deliver(user: loaded) }
    assert_empty deliveries
  end

  # -- what a message looks like ---------------------------------------------

  def test_every_message_carries_a_real_text_part_as_well_as_html
    deliver(subject: "Your Boxd Club sign-in link")
    mail = deliveries.first

    assert mail.multipart?
    assert_equal "text/plain", mail.text_part.content_type.split(";").first
    assert_equal "text/html", mail.html_part.content_type.split(";").first
    assert_equal "Your Boxd Club sign-in link", mail.subject
    assert_equal ["member@example.com"], mail.to
    assert_equal ["boxd@test.boxd.club"], mail.from
  end

  def test_the_subject_reaches_the_title_and_the_preheader
    deliver(subject: "Rank these 5")

    html = deliveries.first.html_part.body.decoded

    assert_includes html, "<title>Rank these 5</title>"
    assert_includes html, %(<span class="preheader">Rank these 5</span>)
  end

  # -- unsubscribing ---------------------------------------------------------

  # Club mail goes to somebody who didn't ask for this particular message, so
  # it has to carry a way out — otherwise the only option is the spam button,
  # and that report costs the sending domain.
  def test_club_mail_carries_an_unsubscribe_link_and_the_headers_for_it
    club = club(members: [@user])
    Mailer.deliver(to: @user.email, user: @user, subject: "s", template: "nudge",
                   club: club, round: round(club, films(1)), candidates: [],
                   waiting_on: 1, club_url: "#{BASE_URL}/club/x")

    mail = deliveries.first
    raw = mail["List-Unsubscribe"].to_s

    assert_match %r{<#{Regexp.escape(BASE_URL)}/unsubscribe/[A-Za-z0-9_-]+>}, raw
    assert_equal "List-Unsubscribe=One-Click", mail["List-Unsubscribe-Post"].to_s
    assert_includes body_of(mail), "unsubscribe"
    # The header's token has to be a live one, or the button 404s.
    refute_nil Tokens.peek(raw[%r{/unsubscribe/([A-Za-z0-9_-]+)}, 1], "unsub")
  end

  # A sign-in link is the one message somebody requests seconds before it
  # arrives, and Gmail puts the unsubscribe button right next to the sender
  # name — where it's easy to hit instead of the link they came for.
  def test_a_sign_in_link_carries_no_unsubscribe_anywhere
    deliver(template: "login")

    mail = deliveries.first

    assert_nil mail["List-Unsubscribe"]
    assert_nil mail["List-Unsubscribe-Post"]
    refute_match(/unsubscribe/i, body_of(mail))
    assert_equal 0, Token.where(purpose: "unsub").count,
                 "an unsent unsubscribe token is still a live capability"
  end

  def test_which_templates_carry_an_unsubscribe
    refute Mailer.unsubscribable?("login")
    assert Mailer.unsubscribable?("invite")
    assert Mailer.unsubscribable?("ballot")
    assert Mailer.unsubscribable?("nudge")
    assert Mailer.unsubscribable?("result")
  end

  # -- wrapping --------------------------------------------------------------

  # The text parts are wrapped by hand, which a sentence out of the database
  # can't be — and a client that doesn't reflow shows one long line running off
  # the side.
  def test_a_sentence_from_the_database_is_wrapped_for_the_text_part
    wrapped = Mailer.wrap("word " * 40, 40)

    assert_operator wrapped.lines.map { |l| l.chomp.length }.max, :<=, 40
    assert_equal "word " * 40, "#{wrapped.tr("\n", ' ')} "
  end

  def test_a_word_longer_than_the_line_is_left_alone_rather_than_cut
    assert_equal "supercalifragilistic", Mailer.wrap("supercalifragilistic", 5)
  end

  def test_wrapping_nothing_is_nothing
    assert_equal "", Mailer.wrap("")
    assert_equal "", Mailer.wrap(nil)
  end
end
