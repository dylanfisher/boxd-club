# Picks the films that go on a club's ballot.
#
# Four sources, set per club (Club#list_mode):
#
#   own    every member's own watchlist, scored by how many people have the
#          film. Requiring a film on *everyone's* list is hopeless past a few
#          people, so this ranks by overlap instead and backfills with
#          single-member picks so obscure entries still surface.
#   cross  only films on every member's watchlist. Strict: if the
#          intersection is empty, no ballot.
#   union  everything on anyone's watchlist, chosen at random.
#   list   one fixed Letterboxd list.
#
# Two rules on top of whichever source, both about not seeing the same films
# week after week:
#
#   A film the club has already chosen — watched or skipped — never comes back.
#
#   A film that has merely been *on a ballot* is held back until the pool of
#   films nobody has seen yet runs out. Only then do repeats come round again,
#   longest-unseen first. Before this, a club with 40 eligible films could get
#   the same five most-shared titles most weeks; now those five are spent and
#   the ballot moves on.
#
# The fallback matters as much as the rule: a small club, or a `cross` club
# with a thin intersection, would otherwise stop producing ballots the moment
# it had seen everything once.

require_relative "models"

module Matcher
  MIN_MATCHES = 2

  # How many candidates to consider when reaching for repeats, as a multiple of
  # the ballot size. Wide enough that "longest unseen" is a real choice rather
  # than whatever the first query happened to return.
  REPEAT_POOL = 4

  module_function

  # Returns [{ film_id:, match_count: }, ...], best first.
  def candidates_for(club, limit: nil)
    limit ||= club.ballot_size
    members = club.voting_members
    return [] if members.empty?

    user_ids = members.select(&:linked?).map(&:id)
    spent = chosen_film_ids(club)
    seen = last_seen(club)

    # First pass: films this club has never had on a ballot at all.
    picks = from_source(club, user_ids, exclude: (spent + seen.keys).uniq, limit: limit)
    return picks if picks.size >= limit

    # The pool is dry, so films come round again — the ones gone longest first.
    taken = spent + picks.map { |p| p[:film_id] }
    repeats = from_source(club, user_ids, exclude: taken, limit: limit * REPEAT_POOL)
              .sort_by { |p| seen[p[:film_id]].to_s }
    picks + repeats.first(limit - picks.size)
  end

  def from_source(club, user_ids, exclude:, limit:)
    case club.list_mode
    when "list"  then from_list(club, exclude: exclude, limit: limit)
    when "cross" then scored(user_ids, exclude: exclude, threshold: user_ids.size, limit: limit)
    when "union" then shuffled(user_ids, exclude: exclude, limit: limit)
    else              overlapping(user_ids, exclude: exclude, limit: limit)
    end
  end

  # The default 'own' mode: prefer overlap, then backfill.
  def overlapping(user_ids, exclude:, limit:)
    picks = scored(user_ids, exclude: exclude, threshold: MIN_MATCHES, limit: limit)
    return picks if picks.size >= limit

    already = exclude + picks.map { |p| p[:film_id] }
    picks + scored(user_ids, exclude: already, threshold: 1, limit: limit - picks.size)
  end

  def shuffled(user_ids, exclude:, limit:)
    return [] if user_ids.empty?

    ds = DB[:watchlist_entries]
         .where(user_id: user_ids)
         .group(:film_id)
         .select { [film_id, count(user_id).as(:match_count)] }
         .order(Sequel.lit("RANDOM()"))
         .limit(limit)
    ds = ds.exclude(film_id: exclude) unless exclude.empty?
    ds.all
  end

  def from_list(club, exclude:, limit:)
    ds = DB[:club_list_entries]
         .where(club_id: club.id)
         .select { [film_id, Sequel.as(0, :match_count)] }
         .order(Sequel.lit("RANDOM()"))
         .limit(limit)
    ds = ds.exclude(film_id: exclude) unless exclude.empty?
    ds.all
  end

  # Films this club has settled on and is done with: every round's winner,
  # whether it was watched or voted past. These never come back.
  def chosen_film_ids(club)
    DB[:rounds].where(club_id: club.id).exclude(winning_film_id: nil).select_map(:winning_film_id)
  end

  # film_id => when it was last on one of this club's ballots.
  #
  # The value is left as SQLite hands it over — max() returns an untyped string,
  # so this is an ISO-8601 string, not a Time. That's fine for the one thing it's
  # used for (sorting oldest-first, which ISO-8601 does lexicographically) and
  # trying to make it a Time is how you end up comparing String to Time.
  def last_seen(club)
    DB[:candidates]
      .join(:rounds, id: :round_id)
      .where(Sequel[:rounds][:club_id] => club.id)
      .group(Sequel[:candidates][:film_id])
      .select {
        [Sequel[:candidates][:film_id],
         max(Sequel[:rounds][:opened_at]).as(:last_seen)]
      }
      .to_hash(:film_id, :last_seen)
  end

  def scored(user_ids, exclude:, threshold:, limit:)
    return [] if limit <= 0 || user_ids.empty? || threshold <= 0

    ds = DB[:watchlist_entries]
         .where(user_id: user_ids)
         .group(:film_id)
         .select { [film_id, count(user_id).as(:match_count)] }
         .having { count(user_id) >= threshold }
         .order(Sequel.desc(:match_count), Sequel.lit("RANDOM()"))
         .limit(limit)
    ds = ds.exclude(film_id: exclude) unless exclude.empty?
    ds.all
  end
end
