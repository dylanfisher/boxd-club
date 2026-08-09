# Outbound mail. Multipart with a real text part — several people will read
# these in clients where the HTML looks wrong.
#
# The HTML parts are Lee Munroe's responsive email template
# (github.com/leemunroe/responsive-html-email-template) in the site's colours:
# emails/layout.html.erb is the skeleton, and each emails/*.html.erb is only the
# body that goes inside it. To look at any of them, /dev/emails in development.

require "erb"

require_relative "models"
require_relative "tokens"

module Mailer
  TEMPLATE_DIR = File.join(APP_ROOT, "emails")

  # Raised when something asks us to mail an address that isn't a saved user.
  Unknown = Class.new(StandardError)

  # Mail somebody asked for and is waiting on, rather than mail we decided to
  # send them: it carries no unsubscribe, in the footer or in the headers. A
  # sign-in link is the one message a member requests seconds before it arrives,
  # and Gmail puts the unsubscribe button next to the sender name where it is
  # easy to hit instead of the link they came for.
  #
  # Only that one. An invite goes to an address that never asked us for
  # anything, which is exactly the mail that has to carry a way out — otherwise
  # the recipient's only option is the spam button, and that is the report that
  # costs us the sending domain. Everything else (ballot, nudge, result) is
  # recurring club mail and keeps it too.
  TRANSACTIONAL = %w[login].freeze

  module_function

  # `user` is the recipient: it decides the unsubscribe link, and templates use
  # it for the greeting.
  def deliver(to:, subject:, template:, user:, **locals)
    # One choke point for every outbound message: we only ever mail an address
    # that already exists in the users table, and only at that row's own
    # address. Without this, any form that takes an email — /login especially —
    # is a way to make this server send mail to a stranger.
    check_recipient!(to, user)
    configure_mail!

    # nil on a transactional template, and the layout and the text parts both
    # read it as "no unsubscribe anywhere in this message". Minting the token is
    # part of the branch: an unsent link is still a live capability.
    unsub = unsubscribable?(template) ? Tokens.url("/unsubscribe", Tokens.issue(user, "unsub")) : nil
    parts = { **locals, user: user, unsub_url: unsub, subject: subject }
    text = render_part(template, :text, **parts)
    html = render_part(template, :html, **parts)
    from = ENV.fetch("MAIL_FROM", "Boxd Club <boxd@localhost>")
    # Receivers check whether the From domain accepts mail, and someone hitting
    # reply should reach a person. Falls back to From when unset.
    reply_to = ENV["MAIL_REPLY_TO"]

    mail = Mail.new do
      to      to
      from    from
      subject subject

      reply_to reply_to if reply_to

      # RFC 8058: lets the client's native unsubscribe button do the right
      # thing instead of people hunting for the link. Both headers or neither —
      # List-Unsubscribe-Post on its own is a one-click promise with nowhere to
      # POST to.
      if unsub
        header["List-Unsubscribe"] = "<#{unsub}>"
        header["List-Unsubscribe-Post"] = "List-Unsubscribe=One-Click"
      end

      text_part do
        content_type "text/plain; charset=UTF-8"
        body text
      end
      html_part do
        content_type "text/html; charset=UTF-8"
        body html
      end
    end

    mail.deliver!
    mail
  end

  # The recipient has to be a saved User, and `to` has to be that user's own
  # address — a template can't be talked into mailing somewhere else.
  def check_recipient!(to, user)
    raise Unknown, "no user given" unless user.is_a?(User) && !user.id.nil?

    address = to.to_s.strip.downcase
    raise Unknown, "no address" if address.empty?

    unless address == user.email.to_s.strip.downcase
      raise Unknown, "#{address} isn't user #{user.id}'s address"
    end

    # Re-read rather than trusting the in-memory object: a User built but never
    # saved, or one deleted since it was loaded, must not be mailable.
    raise Unknown, "no user in the database for #{address}" if User.first(email: user.email).nil?
  end

  # Whether this template's messages carry an unsubscribe. Public because the
  # previews at /dev/emails have to make the same call to show the same footer.
  def unsubscribable?(template) = !TRANSACTIONAL.include?(template.to_s)

  # One part of one message. The text part is its template and nothing else; the
  # HTML part is its template inside the shared layout, which is where the
  # stylesheet, the preheader and the footer live. `subject` has to be in
  # `locals` — the layout puts it in the <title> and the preheader.
  #
  # Public because the email previews at /dev/emails render parts without
  # sending anything, and this is the only way to get the same bytes a member
  # would be sent.
  def render_part(template, part, **locals)
    return render("#{template}.text.erb", **locals) if part.to_sym == :text

    body = render("#{template}.html.erb", **locals)
    render("layout.html.erb", **locals, body: body)
  end

  # The template's call-to-action button — a table, because Outlook won't give a
  # link padding. Here rather than in five templates, since it's the same button
  # every time and only the label and the link change. The colours are inline as
  # well as in the layout's stylesheet: a client that drops the <style> block
  # still gets a green button rather than a bare blue link.
  def button(url, label)
    <<~HTML
      <table role="presentation" border="0" cellpadding="0" cellspacing="0" class="btn btn-primary">
        <tbody>
          <tr>
            <td align="left">
              <table role="presentation" border="0" cellpadding="0" cellspacing="0">
                <tbody>
                  <tr>
                    <td bgcolor="#00c030" style="background-color:#00c030;border-radius:4px;text-align:center"><a href="#{url}" style="background-color:#00c030;border:solid 2px #00c030;border-radius:4px;color:#06240e;display:inline-block;font-size:16px;font-weight:bold;padding:12px 24px;text-decoration:none">#{label}</a></td>
                  </tr>
                </tbody>
              </table>
            </td>
          </tr>
        </tbody>
      </table>
    HTML
  end

  def render(name, **locals)
    path = File.join(TEMPLATE_DIR, name)
    ERB.new(File.read(path), trim_mode: "-").result_with_hash(locals)
  end
end
