# Routes only. Parse params, call into lib/, render. All logic lives in lib/.

require "roda"

require_relative "lib/models"
require_relative "lib/tokens"
require_relative "lib/votes"
require_relative "lib/rounds"
require_relative "lib/clubs"
require_relative "lib/invites"
require_relative "lib/throttle"
require_relative "lib/letterboxd"
require_relative "lib/avatars"
require_relative "lib/quotes"
require_relative "lib/fmt"
require_relative "lib/email_previews" if APP_ENV == "development"

class App < Roda
  # Roda's session cookie needs 64+ bytes. In production this must be set, or
  # every restart signs everybody out.
  SESSION_SECRET = ENV["SESSION_SECRET"] || begin
    raise "SESSION_SECRET is required in production" if APP_ENV == "production"

    SecureRandom.hex(64)
  end

  # Bootstrap: these addresses become admins the first time they sign in, so
  # there's a way into /admin on a brand-new database.
  ADMIN_EMAILS = ENV.fetch("ADMIN_EMAILS", "").downcase.split(",").map(&:strip).reject(&:empty?)

  plugin :render, engine: "erb", views: File.join(APP_ROOT, "views"),
                  layout: "layout", escape: true
  plugin :sessions, secret: SESSION_SECRET, key: "boxd.session"
  plugin :flash

  # The realistic CSRF failure here isn't an attack, it's someone opening a
  # days-old page in a browser that dropped the session cookie. Say so
  # instead of raising a 500.
  plugin :route_csrf, csrf_failure: lambda { |r|
    r.scope.response.status = 403
    r.scope.error_page("That form expired.",
                       detail: "Open the link from your email again and it'll work.",
                       quote: Quotes.random(:expired))
  }
  plugin :head
  plugin :status_handler

  status_handler(404) { error_page("Nothing here.", quote: Quotes.random(:missing)) }
  status_handler(403) { error_page("That isn't yours to look at.", quote: Quotes.random(:forbidden)) }

  plugin :error_handler do |e|
    raise e if APP_ENV == "development"

    warn "[web] #{e.class}: #{e.message}\n#{e.backtrace&.join("\n")}"
    error_page("Something broke.", detail: "Try again in a minute.", quote: Quotes.random(:broken))
  end

  # Public because the CSRF failure lambda reaches it through `r.scope`, and
  # the only caller outside this class is that lambda. Every error page goes
  # through here so the template's three locals are always defined.
  def error_page(message, detail: nil, quote: nil)
    view("error", locals: { message: message, detail: detail, quote: quote })
  end

  route do |r|
    r.root do
      if current_user
        view("home", locals: { user: current_user, clubs: current_user.clubs_dataset.order(:name).all })
      else
        view("login", locals: { sent: false, quote: Quotes.random(:entry) })
      end
    end

    # Members' profile pictures, copied from Letterboxd rather than hotlinked.
    # The filename is checked against the pattern we generate before it touches
    # the filesystem — see Avatars.path_for.
    r.get "avatars", String do |name|
      path = Avatars.path_for(name)
      next not_found unless path

      response["Content-Type"] = Avatars.content_type(name)
      # The filename carries a digest of the source URL, so a changed picture is
      # a changed URL and this can be cached hard.
      response["Cache-Control"] = "public, max-age=31536000, immutable"
      File.binread(path)
    end

    r.on "login" do
      r.get { view("login", locals: { sent: false, quote: Quotes.random(:entry) }) }

      r.post do
        check_csrf!
        email = Invites.normalize(r.params["email"])
        # Both allowances are spent whatever the address turns out to be —
        # checking the user first would make an unknown address cheaper than a
        # real one, which is the enumeration this form already avoids saying
        # out loud.
        next too_many(:login_ip) unless Throttle.allow?(:login_ip, r.ip)
        next too_many(:login_email) unless Throttle.allow?(:login_email, email)

        Invites.send_login(email)
        # Same answer whether or not that address is a member: this form is
        # public, and it shouldn't say who's in the club.
        view("login", locals: { sent: true, quote: Quotes.random(:entry) })
      end
    end

    # Dismissing the "how this works" panel, for good. A POST because it writes,
    # and back to the page they were reading rather than a page of its own.
    r.post "onboarding", "dismiss" do
      check_csrf!
      current_user&.update(onboarded_at: Time.now)
      r.redirect Tokens.safe_path(r.params["to"])
    end

    r.post "logout" do
      check_csrf!
      session.clear
      r.redirect "/"
    end

    # Every emailed link lands here: sign in, then go where the email meant.
    r.get "auth", String do |raw|
      token = Tokens.peek(raw, "login")
      next expired unless token

      sign_in(token.user)
      r.redirect Tokens.safe_path(r.params["to"])
    end

    # Confirm an invited address, then capture their Letterboxd username.
    # The token is consumed only once the username is saved, so a prefetched
    # link doesn't burn the invite.
    r.get "verify", String do |raw|
      token = Tokens.peek(raw, "verify")
      next expired unless token

      view("verify", locals: { token: raw, user: token.user, error: nil })
    end

    r.post "profile", String do |raw|
      token = Tokens.peek(raw, "verify")
      next expired unless token

      check_csrf!
      username = r.params["letterboxd_username"].to_s.strip
                  .sub(%r{\A.*letterboxd\.com/}, "").split("/").first.to_s

      user = token.user
      error = validate_username(username, user)
      next view("verify", locals: { token: raw, user: user, error: error }) if error

      user.update(
        letterboxd_username: username,
        verified_at: user.verified_at || Time.now,
        active: true,
        unsubscribed_at: nil
      )
      Tokens.consume(raw, "verify")
      sign_in(user)
      # Their picture is decoration on a page they haven't seen yet — fetch it
      # off the response path, and never let it fail the signup.
      Rounds.in_background { Avatars.refresh!(user, force: true) }
      view("welcome", locals: { user: user, clubs: user.clubs_dataset.order(:name).all })
    end

    r.on "unsubscribe", String do |raw|
      token = Tokens.peek(raw, "unsub")
      next expired unless token

      r.get { view("unsubscribe", locals: { token: raw, user: token.user }) }

      r.post do
        # RFC 8058 one-click: the mail client POSTs `List-Unsubscribe=One-Click`
        # straight here, with no page to have taken a CSRF token from. The
        # unguessable token in the path is the capability, so there is nothing
        # for CSRF to add — and Gmail and Yahoo both hold a failing unsubscribe
        # against the sending domain, which is not a fight to pick with a
        # brand-new one. The on-page confirm form still carries its token.
        check_csrf! unless r.params["List-Unsubscribe"] == "One-Click"
        token.user.update(active: false, unsubscribed_at: Time.now)
        Tokens.consume(raw, "unsub")
        error_page("Done — you're unsubscribed.",
                   detail: "Ask whoever runs the club to add you back.")
      end
    end

    # The old club URL. Sign-in links live in inboxes for two months, and
    # they carry a ?to= path, so this has to keep working.
    r.on "c", String do |slug|
      # 307 rather than 301 so an old page's POST keeps its method and body.
      r.redirect "/club/#{slug}#{r.remaining_path}", r.get? ? 301 : 307
    end

    r.on "club", String do |slug|
      club = Club.first(slug: slug)
      next not_found unless club
      next r.redirect("/login") unless current_user
      next forbidden unless Clubs.member?(club, current_user) || current_user.admin

      r.is { club_page(club) }

      # One past round, by its per-club number: the ballot as it stood, who
      # won, and the final order.
      r.get "round", String do |number|
        round = Round.first(club_id: club.id, number: number.to_i) ||
                Round.first(club_id: club.id, id: number.to_i)
        next not_found unless round

        view("round", locals: {
               club: club, round: round,
               candidates: round.candidate_films,
               standings: round.open? ? [] : Votes.standings(round)
             })
      end

      # GET must never record a vote: mail scanners prefetch every URL in a
      # message, and would otherwise cast ballots nobody intended.
      r.post "vote" do
        check_csrf!
        round = club.open_round
        next error_page("There's no ballot open right now.") if round.nil?

        # A hand-made request can put anything under `rank` — a bare string, or
        # nested hashes. This checks the shape so it can't raise; whether the
        # contents are a real ballot is Votes.record_ranking!'s job.
        raw_ranking = r.params["rank"]
        raw_ranking = {} unless raw_ranking.is_a?(Hash)
        ranking = raw_ranking.to_h { |cid, rank| [cid.to_i, rank.to_s.to_i] }
        # Asked before recording, since recording is what makes it true.
        again = Votes.voted?(round, current_user)
        begin
          Votes.record_ranking!(round, current_user, ranking)
        rescue Votes::InvalidBallot => e
          next club_page(club, ballot_error: e.message)
        end

        # The last ballot in decides the round then and there.
        Rounds.check_after_vote!(round)

        flash["notice"] = again ? "Ballot updated." : "Ballot submitted."
        r.redirect club.path
      end

      # Vote to skip the film this round chose. Half the club ends it; until
      # then this just records one more voice. POST for the same reason voting
      # is: a prefetched link must not cast anything.
      r.post "skip" do
        check_csrf!
        round = club.current_round
        next error_page("There's nothing to skip right now.") unless round&.decided?

        # Whoever casts the deciding skip shouldn't sit through a round's worth
        # of ballot emails; the new round is committed before this returns.
        Rounds.skip_vote!(round, current_user, deliver: :later)
        round.refresh
        flash["notice"] = if round.skipped?
                            "Skipped — a new round is open."
                          else
                            "Noted. #{round.skips_needed - round.skip_voters.size} more to skip it."
                          end
        r.redirect club.path
      end
    end

    # Every email, rendered from fixtures. Development only, and it can't send:
    # it renders the templates directly rather than going through
    # Mailer.deliver, so there's no recipient and no transport involved.
    r.on "dev", "emails" do
      next not_found unless APP_ENV == "development"

      r.is { view("email_previews", locals: { previews: EmailPreviews.all }) }

      r.on String do |name|
        preview = EmailPreviews[name]
        next not_found unless preview

        # The parts on their own, exactly as a client would get them — the app
        # layout's stylesheet would change how the HTML part looks, so the
        # preview page frames this rather than inlining it.
        r.get "html" do
          response["Content-Type"] = "text/html; charset=UTF-8"
          EmailPreviews.render(preview, :html)
        end

        r.get "text" do
          response["Content-Type"] = "text/plain; charset=UTF-8"
          EmailPreviews.render(preview, :text)
        end

        # `true` rather than a bare `r.get`, which would also answer for
        # /dev/emails/invite/anything-at-all.
        r.get true do
          view("email_preview", locals: {
                 preview: preview,
                 previews: EmailPreviews.all,
                 text: EmailPreviews.render(preview, :text)
               })
        end
      end
    end

    r.on "admin" do
      next r.redirect("/login") unless current_user
      next forbidden unless current_user.admin

      r.is { view("admin_index", locals: { clubs: Club.order(:name).all, users: User.order(:email).all }) }

      r.post "clubs" do
        check_csrf!
        club = Clubs.create!(
          name: r.params["name"],
          list_mode: r.params["list_mode"],
          list_url: r.params["list_url"],
          ballot_size: r.params["ballot_size"].to_s.empty? ? 5 : r.params["ballot_size"]
        )
        flash["notice"] = "Created #{club.name}."
        r.redirect "/admin/clubs/#{club.slug}"
      rescue Clubs::Invalid => e
        flash["error"] = e.message
        r.redirect "/admin"
      end

      r.post "invite" do
        check_csrf!
        next too_many(:invite_ip) unless Throttle.allow?(:invite_ip, r.ip)

        Invites.send!(r.params["email"], admin: r.params["admin"] == "1")
        flash["notice"] = "Invite sent."
        r.redirect "/admin"
      rescue Invites::Invalid => e
        flash["error"] = e.message
        r.redirect "/admin"
      end

      r.on "clubs", String do |club_slug|
        club = Club.first(slug: club_slug)
        next not_found unless club

        r.is do
          r.get { admin_club(club) }

          r.post do
            check_csrf!
            Clubs.update!(
              club,
              name: r.params["name"],
              list_mode: r.params["list_mode"],
              list_url: r.params["list_url"],
              ballot_size: r.params["ballot_size"]
            )
            flash["notice"] = "Saved."
            r.redirect "/admin/clubs/#{club.slug}"
          rescue Clubs::Invalid => e
            flash["error"] = e.message
            r.redirect "/admin/clubs/#{club.slug}"
          end
        end

        r.post "invite" do
          check_csrf!
          next too_many(:invite_ip) unless Throttle.allow?(:invite_ip, r.ip)

          Invites.send!(r.params["email"], club: club)
          flash["notice"] = "Invite sent."
          r.redirect "/admin/clubs/#{club.slug}"
        rescue Invites::Invalid => e
          flash["error"] = e.message
          r.redirect "/admin/clubs/#{club.slug}"
        end

        r.post "remove" do
          check_csrf!
          user = User[r.params["user_id"].to_i]
          Clubs.remove_member!(club, user) if user
          flash["notice"] = "Removed #{user&.email}."
          r.redirect "/admin/clubs/#{club.slug}"
        end

        # Chases everyone who still owes a ballot. Unlike the automatic
        # reminder this ignores the every-3-days throttle, so pressing it twice
        # really does send twice.
        r.post "nudge" do
          check_csrf!
          round = club.open_round
          if round.nil?
            flash["error"] = "No ballot is open, so there's nobody to chase."
          else
            n = Rounds.nudge!(round)
            flash["notice"] = n.zero? ? "Everyone's already voted." : "Nudged #{n} #{n == 1 ? 'person' : 'people'}."
          end
          r.redirect "/admin/clubs/#{club.slug}"
        end

        # Manual overrides for when a club gets stuck: nobody voting, or a
        # winner everyone watched but nobody logged.
        r.post "round", String do |action|
          check_csrf!
          round = club.current_round

          # All four deliver on a background thread: each one can end a round
          # and open the next, which means scraping a film page per candidate
          # and an SMTP round-trip per member. The state change is committed
          # before the response either way, so the page this redirects to is
          # already right. "check" itself stays inline — asking Letterboxd who
          # has logged the winner is the entire point of pressing it.
          case action
          when "open"    then Rounds.open!(club, deliver: :later)
          when "tally"   then round && Rounds.force_tally!(round, deliver: :later)
          when "watched" then round&.decided? && Rounds.mark_watched!(round, deliver: :later)
          when "check"   then round&.decided? && Rounds.check_logs!(round, deliver: :later)
          end

          flash["notice"] = "Done."
          r.redirect "/admin/clubs/#{club.slug}"
        end
      end
    end
  end

  private

  def current_user
    return @current_user if defined?(@current_user)

    id = session["user_id"]
    @current_user = id && User[id]
  end

  def sign_in(user)
    # Bootstrap admins from the environment, so a fresh deploy has a way in.
    user.update(admin: true) if !user.admin && ADMIN_EMAILS.include?(user.email.to_s.downcase)
    # Signing in counts as confirming the address — but never as re-subscribing
    # someone who unsubscribed. They can still read the club page; they just
    # aren't mailed and aren't waited on.
    if !user.active && user.unsubscribed_at.nil?
      user.update(verified_at: user.verified_at || Time.now, active: true)
    end
    session["user_id"] = user.id
    @current_user = user
  end

  def club_page(club, ballot_error: nil)
    round = club.current_round
    candidates = round ? round.candidate_films : []
    existing = round&.open? ? Votes.ranking_for(round, current_user) : {}
    ordered = existing.empty? ? candidates : candidates.sort_by { |c, _f| existing[c.id] || 999 }

    view("club", locals: {
           club: club, user: current_user, round: round,
           candidates: ordered, voted: !existing.empty?,
           standings: round&.decided? ? Votes.standings(round) : [],
           history: club.past_rounds.limit(10).all,
           ballot_error: ballot_error
         })
  end

  def admin_club(club)
    round = club.current_round
    view("admin_club", locals: {
           club: club, round: round,
           candidates: round ? round.candidate_films : [],
           history: club.rounds_dataset.order(Sequel.desc(:opened_at)).limit(20).all
         })
  end

  def validate_username(username, user)
    return "Enter your Letterboxd username." if username.empty?
    return "That doesn't look like a Letterboxd username." unless username.match?(/\A[A-Za-z0-9_]+\z/)

    # Two people on one account would count that watchlist twice.
    if User.where(letterboxd_username: username).exclude(id: user.id).count.positive?
      return "Someone else here is already using that Letterboxd account."
    end

    count = begin
      Letterboxd.check(username)
    rescue Letterboxd::NotFound
      return "No Letterboxd account called #{username}."
    rescue Letterboxd::RateLimited
      nil # Letterboxd is being cagey; accept the name and let the fetch sort it out.
    rescue Letterboxd::Error, SocketError, SystemCallError
      nil
    end

    if count == 0
      return "#{username}'s watchlist looks empty or private. Make it public, then try again."
    end

    nil
  end

  def expired
    error_page("That link has expired or already been used.", quote: Quotes.random(:expired))
  end

  # Over a rate limit. 429 rather than a flash, so the answer is the same
  # whether it came from the form or from a script hammering it.
  def too_many(name)
    response.status = 429
    error_page("Too many requests.",
               detail: "You've asked for that a few times already. Try again in #{Throttle.window_label(name)}.",
               quote: Quotes.random(:broken))
  end

  def not_found
    response.status = 404
    error_page("Nothing here.", quote: Quotes.random(:missing))
  end

  def forbidden
    response.status = 403
    error_page("That isn't yours to look at.", quote: Quotes.random(:forbidden))
  end
end
