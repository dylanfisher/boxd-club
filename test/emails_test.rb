# Every email template, rendered.
#
# lib/email_previews.rb already builds a fixture for each one — including the
# variants that exist because they render a branch the plain version doesn't
# (a stale ballot, a random result, an invite with no club). Rendering the lot
# catches the failure nobody sees until a message is actually sent: a template
# edited without its counterpart, or a local that quietly went missing.

require_relative "helper"
require_relative "../lib/email_previews"

class EmailsTest < BoxdTest
  EmailPreviews::NAMES.each do |name|
    define_method("test_#{name.tr('-', '_')}_renders") do
      preview = EmailPreviews[name]
      refute_nil preview, name

      text = EmailPreviews.render(preview, :text)
      html = EmailPreviews.render(preview, :html)

      refute_empty text.strip
      assert_includes html, "<!doctype html>"
      assert_includes html, preview[:subject], "the subject belongs in the title and preheader"
      # ERB leaves the literal word when a local is nil where a string was
      # meant, and an empty <a href> is a dead button.
      refute_includes text, "#<"
      refute_includes html, 'href=""'
    end
  end

  # Every link in an email is opened out of an inbox, where a relative path
  # resolves against nothing.
  def test_every_link_in_every_email_is_absolute
    EmailPreviews::NAMES.each do |name|
      html = EmailPreviews.render(EmailPreviews[name], :html)

      html.scan(/href="([^"]*)"/).flatten.each do |href|
        assert_match %r{\Ahttps?://}, href, "#{name}: #{href}"
      end
    end
  end

  # The text part is what several people will actually read.
  def test_the_text_part_is_not_just_the_html_with_the_tags_taken_out
    EmailPreviews::NAMES.each do |name|
      text = EmailPreviews.render(EmailPreviews[name], :text)

      refute_match(/<(table|div|span|a)\b/, text, name)
    end
  end

  # The prose in the invite and the sign-in mail is the part built from a
  # sentence out of the database, so it's the part that goes through
  # Mailer.wrap. (The ballot and nudge film lists don't, and run to 133
  # characters on a long title — worth wrapping, but it isn't what these
  # templates promise today, so this only checks the ones that do.)
  def test_the_prose_built_at_runtime_is_wrapped
    %w[invite invite-list login-club].each do |name|
      EmailPreviews.render(EmailPreviews[name], :text).lines.each do |line|
        # URLs are exempt: breaking one breaks the link.
        next if line.include?("http")

        assert_operator line.chomp.length, :<=, 80, "#{name}: #{line}"
      end
    end
  end

  # A preview must never be able to send anything or write anything — it's
  # built from unsaved objects and renders the templates directly.
  def test_rendering_a_preview_sends_nothing_and_saves_nothing
    before = DB.tables.to_h { |t| [t, DB[t].count] }

    EmailPreviews.all.each { |p| EmailPreviews.render(p, :html) }

    assert_empty deliveries
    assert_equal before, DB.tables.to_h { |t| [t, DB[t].count] }
  end

  def test_an_unknown_preview_is_nothing
    assert_nil EmailPreviews["not-a-preview"]
  end
end
