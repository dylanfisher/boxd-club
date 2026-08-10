# Sequel::Model classes. Requiring this file hits the database for schema
# reflection, so migrations must have run first.

require_relative "../config/boot"

class User < Sequel::Model
  one_to_many :tokens
  one_to_many :votes
  one_to_many :memberships
  many_to_many :clubs, join_table: :memberships
  many_to_many :films, join_table: :watchlist_entries

  # Reachable: active, verified, not unsubscribed. A member without a
  # Letterboxd username still votes — they just contribute no watchlist and
  # can't be waited on for logging.
  dataset_module do
    def reachable
      where(active: true, unsubscribed_at: nil).exclude(verified_at: nil)
    end
  end

  def display_name = letterboxd_username || email.split("@").first
  # The onboarding panel is for invited members, who arrive knowing nothing
  # about the site. An admin set the club up, so they've seen how it works.
  def needs_onboarding? = !admin && onboarded_at.nil?
  def linked? = !letterboxd_username.to_s.empty?

  # The nudge to upload a watch history, at the foot of every page. Only for
  # people it would actually change something for: a member of a club that
  # draws on a fixed list, with an account to read, who hasn't uploaded one and
  # hasn't waved the panel away. The other three modes read watchlists, which
  # are unwatched by definition, so their ballots don't need any of this.
  def needs_watched_import?
    return false unless linked?
    return false unless watched_imported_at.nil? && import_dismissed_at.nil?

    clubs_dataset.where(active: true, list_mode: "list").any?
  end
  def reachable? = active && unsubscribed_at.nil? && !verified_at.nil?
  def watchlist_size = DB[:watchlist_entries].where(user_id: id).count
  def letterboxd_url = linked? ? "https://letterboxd.com/#{letterboxd_username}/" : nil

  # Where to point an <img> for this member's face, or nil if we have none —
  # a local copy first, then a hotlinked Gravatar. See lib/avatars.rb.
  def avatar_src
    return "/avatars/#{avatar_file}" unless avatar_file.to_s.empty?

    avatar_url
  end

  # Stands in for a missing avatar.
  def initial = display_name.to_s[0]&.upcase || "?"

  def watchlist_fetched_at
    # .get returns a typed Time; .max would return an untyped string.
    DB[:watchlist_entries].where(user_id: id).order(Sequel.desc(:fetched_at)).get(:fetched_at)
  end
end

class Club < Sequel::Model
  MODES = %w[own cross union list].freeze
  MODE_LABELS = {
    "own" => "Everyone's own watchlist",
    "cross" => "Only films on every member's watchlist",
    "union" => "Every film on anyone's watchlist",
    "list" => "One fixed Letterboxd list"
  }.freeze

  # All three watchlist modes read the same pool — every member's watchlist.
  # What differs is how much overlap a film needs to make the ballot, which is
  # the part nobody guesses right from the label alone.
  MODE_NOTES = {
    "own" => "Films at least two of you already want, most-shared first — then " \
             "single-picks to fill the ballot, so nobody's odd choices vanish.",
    "cross" => "Strict overlap: a film has to be on every single watchlist — " \
               "though members without one sit it out rather than emptying the " \
               "overlap for everyone. Past a handful of people the overlap is " \
               "usually empty, and then no ballot goes out.",
    "union" => "Anything on anyone's watchlist, drawn at random. Overlap counts " \
               "for nothing, so expect films only one of you has heard of.",
    "list" => "Ignores watchlists entirely and draws at random from one public " \
              "Letterboxd list, skipping anything a member has already watched. " \
              "We can only see everyone's 72 most recent films, so import your " \
              "watched.csv from Settings and it'll skip a great deal more."
  }.freeze

  # Shown next to the mode wherever a member (not just an admin) sees it.
  MODE_ICONS = { "own" => "◍", "cross" => "◎", "union" => "◌", "list" => "▤" }.freeze

  one_to_many :memberships
  one_to_many :rounds, order: Sequel.desc(:opened_at)
  many_to_many :users, join_table: :memberships

  def members = users_dataset.order(:email).all
  def voting_members = users_dataset.reachable.order(:email).all
  # Only members with a Letterboxd account can be waited on for a log entry.
  def linked_members = voting_members.select(&:linked?)

  def current_round = rounds_dataset.exclude(state: Round::FINISHED).order(Sequel.desc(:opened_at)).first
  def open_round = rounds_dataset.where(state: "open").order(Sequel.desc(:opened_at)).first
  def last_watched = rounds_dataset.where(state: "watched").order(Sequel.desc(:watched_at)).first

  def mode_label = MODE_LABELS.fetch(list_mode, list_mode)
  def mode_note = MODE_NOTES.fetch(list_mode, "")
  def mode_icon = MODE_ICONS.fetch(list_mode, "◍")
  def list_url = list_owner && list_slug ? "https://letterboxd.com/#{list_owner}/list/#{list_slug}/" : nil
  def path = "/club/#{slug}"

  # The club's copy of its Letterboxd list. Empty and never-read look the same
  # in a bare count and need different fixes — one is a private or emptied
  # list, the other a club created since the last fetch — so expose both.
  def list_size = DB[:club_list_entries].where(club_id: id).count

  def list_fetched_at
    DB[:club_list_entries].where(club_id: id).order(Sequel.desc(:fetched_at)).get(:fetched_at)
  end

  def watched_rounds = rounds_dataset.where(state: "watched").order(Sequel.desc(:watched_at))

  # A club with no round yet has nothing to wait on — "the next round starts
  # once the last film is logged" reads as a broken promise when there has
  # never been a film. Until the first round opens, say so plainly.
  def never_started? = rounds_dataset.empty?

  # Everything the club has been through, newest first. Skipped rounds belong
  # here too — "we picked this and dropped it" is history worth keeping.
  def past_rounds = rounds_dataset.where(state: Round::FINISHED).order(Sequel.desc(:opened_at))
  # The header numbers: what the club has got through, and how much film it
  # sifted to get there. `rounds_played` counts skipped rounds too, so the gap
  # between it and `films_watched` is the club's change of heart.
  def films_watched = rounds_dataset.where(state: "watched").count
  def rounds_played = past_rounds.count
  # Distinct films, not ballot slots — a film that keeps coming back and losing
  # is one film shortlisted, however many rounds it has haunted.
  def films_shortlisted
    DB[:candidates].where(round_id: rounds_dataset.select(:id))
                   .distinct.select(:film_id).count
  end

  # What the next round opened gets called. Numbering is per club and never
  # reused, so a round that's been deleted still leaves a gap rather than
  # renaming history.
  def next_round_number = (rounds_dataset.max(:number) || 0) + 1
end

class Membership < Sequel::Model
  many_to_one :club
  many_to_one :user
end

class Token < Sequel::Model
  many_to_one :user

  def expired? = expires_at && expires_at < Time.now
  def used? = !used_at.nil?
end

class Film < Sequel::Model
  # Every reference to a film carries title, year, director and rating —
  # that's the house style, so it lives here rather than in each template.
  def display
    parts = [year ? "#{title} (#{year})" : title]
    parts << "dir. #{director}" if director
    parts << "#{format('%.2f', rating)}/5 on Letterboxd" if rating
    parts.join(" · ")
  end

  def title_with_year = year ? "#{title} (#{year})" : title
  def rating_display = rating ? format("%.2f", rating) : nil
  def letterboxd_url = "https://letterboxd.com/film/#{slug}/"
  def stale_details? = details_fetched_at.nil?
end

class Round < Sequel::Model
  # States a round never comes back from: it's either been watched by everyone
  # or voted past. Either way the club has moved on.
  FINISHED = %w[watched skipped].freeze

  one_to_many :candidates, order: :position
  one_to_many :votes
  many_to_one :club
  many_to_one :winning_film, class: :Film

  dataset_module do
    def open_rounds = where(state: "open")
  end

  def open? = state == "open"
  def decided? = state == "decided"
  def watched? = state == "watched"
  def skipped? = state == "skipped"
  def finished? = FINISHED.include?(state)
  # When it ended, whichever way it ended.
  def ended_at = watched_at || skipped_at

  # Rounds from before numbering existed, and any the migration missed, fall
  # back to the id so a label and a permalink always resolve to something.
  def label = "Round #{number || id}"
  def path = "#{club.path}/round/#{number || id}"

  def candidate_films = candidates.map { |c| [c, Film[c.film_id]] }
  # Just the films, for the times a template wants posters and nothing else.
  def films = candidates.map { |c| Film[c.film_id] }.compact

  def voter_ids = DB[:votes].where(round_id: id).distinct.select_map(:user_id)
  def logged_user_ids = DB[:watch_logs].where(round_id: id).select_map(:user_id)

  # Everyone who still owes a ballot.
  def pending_voters = club.voting_members.reject { |u| voter_ids.include?(u.id) }
  # And everyone who's already in. Who's voted is as much use as who hasn't:
  # if you're the last one left, the club is waiting on you alone.
  def cast_voters = club.voting_members.select { |u| voter_ids.include?(u.id) }
  # Everyone who still owes a Letterboxd log entry for the winner.
  def pending_loggers = club.linked_members.reject { |u| logged_user_ids.include?(u.id) }

  # Voting to skip the film this round landed on. See db/migrate/004.
  def skip_voter_ids = DB[:skip_votes].where(round_id: id).select_map(:user_id)
  def skip_voters = club.voting_members.select { |u| skip_voter_ids.include?(u.id) }
  def skipped_by?(user) = !user.nil? && skip_voter_ids.include?(user.id)
  # Half the club rounded up, but never fewer than two, so no one skips a film
  # on their own: 2 of 2, 2 of 3, 2 of 4, 3 of 5. A solo club is the exception —
  # its one member is the whole club, so one vote carries.
  def skips_needed
    size = club.voting_members.size
    [[[(size / 2.0).ceil, 2].max, size].min, 1].max
  end
end

class Candidate < Sequel::Model
  many_to_one :round
  many_to_one :film
  one_to_many :votes
end

class Vote < Sequel::Model
  many_to_one :round
  many_to_one :user
  many_to_one :candidate
end
