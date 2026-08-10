# Getting people in: invites (admin sends one) and sign-in links (a member asks
# for one). Both are magic links; there is no public signup, because an
# unauthenticated form that emails arbitrary addresses is a spam vector.
#
# The sign-in form at /login only ever mails an address that already exists as a
# user, and says the same thing either way.

require_relative "models"
require_relative "clubs"
require_relative "tokens"
require_relative "mailer"

module Invites
  Invalid = Class.new(StandardError)

  module_function

  # Invites someone, optionally straight into a club. Someone already set up
  # gets a sign-in link instead of a "set your username" one.
  def send!(email, club: nil, admin: false)
    email = normalize(email)
    raise Invalid, "That doesn't look like an email address." unless email.match?(/\A[^@\s]+@[^@\s]+\.[^@\s]+\z/)

    user = User.first(email: email) || User.create(email: email)
    user.update(admin: true) if admin && !user.admin
    Clubs.add_member!(club, user) if club

    if user.reachable? && user.linked?
      deliver_login(user, club: club)
    else
      deliver_invite(user, club: club)
    end
  end

  # The /login form. Returns nil for an unknown address — the caller says the
  # same thing either way, so this can't be used to test who's a member.
  #
  # An unsubscribed member still gets one. Unsubscribing means we stop mailing
  # them club news, not that they lose the account: this is the only door in,
  # /login deliberately says the same thing either way, so refusing here is
  # silence with no explanation and no way back. They can turn club mail on
  # again from /settings once they're through it.
  def send_login(email)
    user = User.first(email: normalize(email))
    return nil if user.nil?

    deliver_login(user)
  end

  def deliver_invite(user, club: nil)
    raw = Tokens.issue(user, "verify")
    url = Tokens.url("/verify", raw)
    Mailer.deliver(
      to: user.email, user: user,
      subject: club ? "You're invited to #{club.name}" : "You're invited to Boxd Club",
      template: "invite",
      club: club, verify_url: url
    )
    log(user, url)
    { user: user, url: url, kind: :invite }
  end

  def deliver_login(user, club: nil)
    url = Tokens.login_url(user, club ? club.path : "/")
    Mailer.deliver(
      to: user.email, user: user,
      subject: club ? "You've been added to #{club.name}" : "Your Boxd Club sign-in link",
      template: "login",
      club: club, login_url: url
    )
    log(user, url)
    { user: user, url: url, kind: :login }
  end

  def normalize(email) = email.to_s.strip.downcase

  # With no SMTP configured, mail goes to the log — so put the link somewhere
  # findable, otherwise local development is a dead end.
  def log(user, url)
    puts "[invite] #{user.email}"
    puts "[invite]   #{url}" if ENV["SMTP_HOST"].to_s.empty?
  end
end
