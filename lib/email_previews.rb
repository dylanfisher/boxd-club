# Fixture data for the email previews at /dev/emails — Rails' mailer previews,
# for this app. Development only.
#
# Everything here is built with unsaved model objects, so a preview needs no
# club, no round and no member, renders the same on an empty database, and can
# never send anything or write anything. Posters are real Letterboxd URLs, each
# belonging to the film it's shown against.

require_relative "models"
require_relative "mailer"

module EmailPreviews
  # In the order they'd happen to a member: invited, signed in, sent a ballot,
  # chased, told the result. Each variant exists because it renders a branch
  # the plain one doesn't.
  NAMES = %w[
    invite invite-general
    login login-club
    ballot ballot-stale
    nudge
    result result-random
  ].freeze

  # Fixture films: two with a director and a rating, one with neither, one
  # long enough to wrap. The last is deliberately left without a poster, so it
  # always renders the no-poster branch.
  #
  # Posters are each film's own, pinned here rather than borrowed from the
  # database: a borrowed poster belongs to some unrelated film, and a preview
  # showing Brave's poster over "The Conversation (1974)" tells you nothing
  # about how a real ballot looks. Pinned URLs also keep a preview identical on
  # an empty database, like the rest of this file.
  LB = "https://a.ltrbxd.com/resized"
  FILMS = [
    { slug: "the-conversation", title: "The Conversation", year: 1974,
      director: "Francis Ford Coppola", rating: 4.21,
      poster_url: "#{LB}/film-poster/5/1/5/2/9/51529-the-conversation-0-600-0-900-crop.jpg" },
    { slug: "chungking-express", title: "Chungking Express", year: 1994,
      director: "Wong Kar-wai", rating: 4.32,
      poster_url: "#{LB}/film-poster/4/5/6/0/2/45602-chungking-express-0-600-0-900-crop.jpg" },
    { slug: "the-assassination-of-jesse-james-by-the-coward-robert-ford",
      title: "The Assassination of Jesse James by the Coward Robert Ford",
      year: 2007, director: "Andrew Dominik", rating: 4.05,
      poster_url: "#{LB}/film-poster/4/9/2/8/8/49288-the-assassination-of-jesse-james-by-the-coward-robert-ford-0-600-0-900-crop.jpg" },
    { slug: "the-red-shoes", title: "The Red Shoes", year: 1948,
      director: "Michael Powell", rating: 4.18,
      poster_url: "#{LB}/sm/upload/rh/3s/bc/rr/oyOtIdNJJO8zVwPyCtxVRxPLuHO-0-600-0-900-crop.jpg" },
    { slug: "a-film-nobody-enriched", title: "A Film Nobody Enriched", year: nil,
      director: nil, rating: nil, poster_url: nil }
  ].freeze

  MATCH_COUNTS = [4, 4, 3, 3, 2].freeze

  module_function

  def all = NAMES.map { |name| build(name) }

  def [](name) = NAMES.include?(name) ? build(name) : nil

  # `part` is :html or :text — the two parts Mailer.deliver sends, rendered the
  # same way it renders them, layout and all.
  def render(preview, part)
    Mailer.render_part(preview[:template], part, **preview[:locals])
  end

  def build(name)
    case name
    when "invite"
      preview(name, "invite", "You're invited to #{club.name}",
              "An invite to a club", club: club, verify_url: url("/verify"))
    when "invite-general"
      preview(name, "invite", "You're invited to Boxd Club",
              "An invite with no club yet", club: nil, verify_url: url("/verify"))
    when "login"
      preview(name, "login", "Your Boxd Club sign-in link",
              "The /login form", club: nil, login_url: url("/auth"))
    when "login-club"
      preview(name, "login", "Your link to #{club.name}",
              "A sign-in link aimed at a club", club: club, login_url: url("/auth"))
    when "ballot"
      preview(name, "ballot", "#{club.name} #{round.label.downcase} — rank these #{FILMS.size}",
              "A new round, sent to everyone", **ballot_locals)
    when "ballot-stale"
      preview(name, "ballot", "#{club.name} #{round.label.downcase} — rank these #{FILMS.size}",
              "A ballot built on watchlists we couldn't refresh",
              **ballot_locals, stale: %w[alice bob])
    when "nudge"
      preview(name, "nudge",
              "#{club.name} — still waiting on your ballot (#{round.label.downcase})",
              "The reminder for whoever still owes a ballot",
              club: club, round: round, candidates: candidates, waiting_on: 2,
              club_url: url("/auth"))
    when "result"
      preview(name, "result", "#{club.name} #{round.label.downcase} — we're watching #{films.first.title}",
              "A round decided by the votes",
              **result_locals, standings: standings, random: false)
    when "result-random"
      preview(name, "result", "#{club.name} #{round.label.downcase} — we're watching #{films.first.title}",
              "A round nobody voted in, decided by coin toss",
              **result_locals, standings: [], random: true)
    end
  end

  # `subject` goes into the locals as well as the preview itself: the layout puts
  # it in the <title> and the preheader, the same as a real send does.
  def preview(name, template, subject, note, **locals)
    { name: name, template: template, subject: subject, note: note,
      locals: { user: user, unsub_url: url("/unsubscribe"), subject: subject }.merge(locals) }
  end

  def ballot_locals
    { club: club, round: round, candidates: candidates,
      member_count: 5, stale: [], club_url: url("/auth") }
  end

  def result_locals
    { club: club, round: round, film: films.first, club_url: url("/auth") }
  end

  def user = User.new(email: "you@example.com", letterboxd_username: "you")
  def club = Club.new(name: "Thursday Club", slug: "thursday-club")
  def round = Round.new(number: 7, state: "open")

  # What Round#candidate_films returns: [candidate, film] pairs, in ballot order.
  def candidates
    films.each_with_index.map do |film, i|
      [Candidate.new(position: i + 1, match_count: MATCH_COUNTS[i]), film]
    end
  end

  # What Votes.standings returns, highest first.
  def standings
    points = [19, 16, 14, 9, 7]
    firsts = [3, 1, 1, 0, 0]
    films.each_with_index.map do |film, i|
      { film: film, points: points[i], firsts: firsts[i] }
    end
  end

  def films = FILMS.map { |attrs| Film.new(**attrs) }

  # Links are dead on purpose: a preview shouldn't mint a real token, and a
  # token is the one thing in an email you can't take back once it's clicked.
  def url(path) = "#{BASE_URL}#{path}/preview-token-not-a-real-link"
end
