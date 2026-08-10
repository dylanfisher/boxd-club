# Picks the films that go on a club's ballot.
#
# Four sources, set per club (Club#list_mode):
#
#   own    every member's own watchlist, scored by how many people have the
#          film. Requiring a film on *everyone's* list is hopeless past a few
#          people, so this ranks by overlap instead and backfills with
#          single-member picks so obscure entries still surface.
#   cross  only films on every watchlist. Strict: if the intersection is empty,
#          no ballot. Members without a watchlist sit it out rather than
#          emptying the intersection for everyone.
#   union  everything on anyone's watchlist, chosen at random.
#   list   one fixed Letterboxd list, minus anything a member has already
#          watched — see lib/seen.rb. The other three modes need no such filter,
#          since a watchlist is by definition films you haven't seen.
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
require_relative "seen"

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
    picks += repeats.first(limit - picks.size)
    return picks if picks.size >= limit

    # Still short: every film left is one the club has seen. Last resort.
    picks + backfill(club, user_ids, exclude: taken + picks.map { |p| p[:film_id] },
                                     limit: limit - picks.size)
  end

  def from_source(club, user_ids, exclude:, limit:)
    case club.list_mode
    when "list"  then list_rows(club, exclude: exclude, seen_by: user_ids, limit: limit)
    when "cross" then cross(user_ids, exclude: exclude, limit: limit)
    when "union" then shuffled(user_ids, exclude: exclude, limit: limit)
    else              overlapping(user_ids, exclude: exclude, limit: limit)
    end
  end

  # 'cross' mode: on every watchlist. The intersection is taken over the members
  # who actually have a watchlist, not every linked member — one empty list
  # (never scraped, genuinely empty, or emptied by a fetch that died partway
  # through) would otherwise make the intersection empty forever and quietly
  # stop the club getting ballots at all.
  def cross(user_ids, exclude:, limit:)
    contributing = DB[:watchlist_entries].where(user_id: user_ids).distinct.select_map(:user_id)
    scored(contributing, exclude: exclude, threshold: contributing.size, limit: limit)
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

  # After both passes have come up short: a list club that has worked through
  # its list would otherwise stop getting ballots the moment everyone had seen
  # what was left. Rather than send nothing, fill up with what the fewest of
  # them have seen.
  #
  # Out here rather than inside the 'list' branch on purpose. Filling the ballot
  # in there meant the first pass always came back full, so candidates_for never
  # saw a dry pool and the repeat pass — films that have merely been on a ballot
  # before, longest-unseen first — never ran for a list club at all. A film
  # nobody has watched but the club has already been offered beats one they've
  # all seen, so this has to be the last thing tried, not the second.
  #
  # The other three modes read watchlists, which are by definition unwatched, so
  # there's nothing here for them: an empty ballot means an empty watchlist.
  def backfill(club, user_ids, exclude:, limit:)
    return [] unless club.list_mode == "list"

    least_seen(club, user_ids, exclude: exclude, limit: limit)
  end

  # 'list' mode: the club's fixed list, minus every film a member has already
  # watched, drawn at random. Nobody having seen it is the bar — one member's
  # 'yes' is enough to drop a film, since the point of the club is watching
  # something together for the first time.
  #
  # Films nobody has been asked about pass, so a club whose seen cache is still
  # cold gets the same ballot it always did (lib/seen.rb explains why that's the
  # right way round).
  #
  # `seen_by` is dropped as a subquery rather than a list of ids: an imported
  # history is thousands of films per member, which is not something to inline
  # into a NOT IN.
  def list_rows(club, exclude:, limit:, seen_by: nil)
    return [] if limit <= 0

    ds = DB[:club_list_entries]
         .where(club_id: club.id)
         .select { [film_id, Sequel.as(0, :match_count)] }
         .order(Sequel.lit("RANDOM()"))
         .limit(limit)
    ds = ds.exclude(film_id: exclude) unless exclude.empty?
    ds = ds.exclude(film_id: Seen.watched(seen_by)) unless seen_by.nil? || seen_by.empty?
    ds.all
  end

  # Whatever's left of the list, least-watched first. Shuffled before the sort
  # rather than after, so films tied on the same count — which is most of them —
  # come out in a different order each time.
  def least_seen(club, user_ids, exclude:, limit:)
    return [] if limit <= 0

    ds = DB[:club_list_entries].where(club_id: club.id)
    ds = ds.exclude(film_id: exclude) unless exclude.empty?

    ids = ds.select_map(:film_id)
    counts = Seen.counts(user_ids, ids)
    ids.shuffle
      .sort_by { |id| counts[id] || 0 }
      .first(limit)
      .map { |id| { film_id: id, match_count: 0 } }
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
