# Which films a club's members have already watched.
#
# The three watchlist modes get this for free — a watchlist is by definition
# films you haven't seen. 'list' mode has no such guarantee: point a club at the
# Official Top 500 and the obvious ballot is five films the club has
# collectively seen four times over.
#
# Letterboxd won't hand over a watch history in bulk, so this is filled from the
# two sources that do answer: an uploaded watched.csv, which is the whole
# history at once, and the member's RSS feed, which the nightly fetch reads for
# whatever they've logged since (Letterboxd.refresh_watched!). Both are lists of
# films somebody has watched.
#
# So every row here is a yes. Nothing writes a no — there's no route that can
# tell us a member *hasn't* watched something, only ones that list what they
# have. A film not in this table is a film nobody has mentioned, which is the
# safe way round: a club whose record is cold behaves exactly as it did before
# any of this existed, and the filter tightens as the record fills, rather than
# a new club going ballot-less on the strength of data we haven't collected.
#
# The matcher only ever reads what's here and never blocks on the network —
# lib/rounds.rb deliberately doesn't scrape while opening a round.

require_relative "models"

module Seen
  module_function

  # Films any of these members has watched. This is the exclusion the matcher
  # applies — everything else, mentioned or not, is fair game.
  #
  # `seen: true` on every one of these queries, though nothing writes anything
  # else any more: rows from the per-film checks this used to do outlived them,
  # and a stored 'no' was never evidence of much.
  #
  # A dataset rather than an array of ids: an imported history runs to thousands
  # of films per member, and the matcher's `exclude` would otherwise become a
  # NOT IN with twenty thousand literals in it.
  def watched(user_ids)
    DB[:seen_checks].where(user_id: user_ids, seen: true).select(:film_id)
  end

  # How much of this club's list somebody has already watched — the number that
  # explains a thin ballot, so it belongs next to the list rather than counting
  # every film any member has ever seen.
  def watched_on_list_count(club, user_ids)
    return 0 if user_ids.empty?

    DB[:club_list_entries].where(club_id: club.id, film_id: watched(user_ids)).count
  end

  # The same, per member: user_id => how much of the club's list they've been
  # found to have watched. Members with none are absent rather than zero;
  # callers treat a miss as zero.
  def watched_on_list_counts(club, user_ids)
    return {} if user_ids.empty?

    DB[:seen_checks]
      .where(user_id: user_ids, seen: true)
      .where(film_id: DB[:club_list_entries].where(club_id: club.id).select(:film_id))
      .group(:user_id)
      .select { [user_id, count(film_id).as(:watched_count)] }
      .to_hash(:user_id, :watched_count)
  end

  # How many films we know this member has watched. Shown on /settings, where
  # the number is the answer to "did my import work?".
  def user_count(user_id)
    DB[:seen_checks].where(user_id: user_id, seen: true).count
  end

  # film_id => how many of these members have seen it, over the films asked
  # about. Films nobody has seen are absent rather than zero; callers treat a
  # miss as zero.
  def counts(user_ids, film_ids)
    return {} if user_ids.empty? || film_ids.empty?

    DB[:seen_checks]
      .where(user_id: user_ids, film_id: film_ids, seen: true)
      .group(:film_id)
      .select { [film_id, count(user_id).as(:seen_count)] }
      .to_hash(:film_id, :seen_count)
  end

  # The films in one batch — a member's feed, or an uploaded export. Only ever
  # promotes: a film in one of those is watched, and a film missing from it has
  # merely not been mentioned, which is not an answer.
  #
  # Films still on the member's own watchlist are skipped. Partly as a guard —
  # the two export files have identical columns, so a mis-picked watchlist.csv
  # would otherwise mark everything they want to see as seen — and partly
  # because it's the right answer anyway: a film someone has put back on their
  # watchlist is one they want to watch, whatever they did with it before.
  def record_seen!(user_id, film_ids)
    film_ids = film_ids.uniq
    return 0 if film_ids.empty?

    wanted = DB[:watchlist_entries].where(user_id: user_id, film_id: film_ids).select_map(:film_id)
    film_ids -= wanted
    return 0 if film_ids.empty?

    # One statement, not one per film: an imported history is thousands of
    # them, and this runs on the request thread. Deduplicated above because
    # ON CONFLICT DO UPDATE refuses to touch the same row twice in one insert.
    now = Time.now
    DB[:seen_checks]
      .insert_conflict(target: %i[user_id film_id], update: { seen: true, checked_at: now })
      .import(%i[user_id film_id seen checked_at],
              film_ids.map { |film_id| [user_id, film_id, true, now] })
    film_ids.size
  end
end
