# Which films a club's members have already watched.
#
# The three watchlist modes get this for free — a watchlist is by definition
# films you haven't seen. 'list' mode has no such guarantee: point a club at the
# Official Top 500 and the obvious ballot is five films the club has
# collectively seen four times over.
#
# Letterboxd won't hand over a watch history in bulk. /{user}/films/ returns the
# 72 most recent and nothing else: every paginated form of that route —
# /page/2/, /by/date/, /by/name/, /rated/… — comes back 403 with
# `cf-mitigated: challenge` (checked 2026-08-09), while watchlist and list
# pagination stay open. So the bulk of this is built from the one route that
# does answer reliably, /{user}/film/{slug}/, which is 200 if they've logged the
# film and 404 if they haven't. One request, one member, one film.
#
# At that price a 500-film list can't be checked at ballot time, and
# lib/rounds.rb deliberately never scrapes while opening a round. So the answers
# live in `seen_checks` and the nightly fetch fills them in a bounded number at
# a time (Letterboxd.warm_seen!). This file is the database half of that: the
# matcher only ever reads the cache, and never blocks on the network.
#
# A film nobody has been asked about counts as unseen. That's the safe way
# round — a club whose cache is cold behaves exactly as it did before any of
# this existed, and the filter tightens as the cache fills, rather than a new
# club going ballot-less on the strength of data we haven't collected yet.

require_relative "models"

module Seen
  # How much verified-unseen film to keep in hand per ballot slot before the
  # nightly warm leaves a club alone. Wide enough that the random draw has a
  # real choice, small enough that a settled club costs nothing most nights.
  RESERVE = 4

  module_function

  # Films any of these members has watched. This is the exclusion the matcher
  # applies — everything else, checked or not, is fair game.
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

  def record!(user_id:, film_id:, seen:)
    DB[:seen_checks]
      .insert_conflict(target: %i[user_id film_id], update: { seen: seen, checked_at: Time.now })
      .insert(user_id: user_id, film_id: film_id, seen: seen, checked_at: Time.now)
  end

  # Bulk 'yes' rows, from the 72-film scrape of /{user}/films/ or an uploaded
  # export. Only ever promotes: a film in one of those batches is watched, and a
  # film missing from it has merely not been mentioned, which is not an answer.
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

  # Films on the club's list that every member has been checked against and
  # nobody has seen — the pool the ballot can draw from with confidence.
  #
  # Counting `seen: false` rows is the whole test: a film with one false row per
  # member has been asked about everybody and come back clean, because a single
  # 'yes' would have taken one of those rows away.
  #
  # Films the club has already settled on don't count: they can never be
  # offered again, so a club whose remaining unseen film has all been watched
  # together is out of stock, not stocked.
  def verified_unseen_count(club, user_ids)
    return 0 if user_ids.empty?

    DB[:club_list_entries]
      .where(club_id: club.id)
      .where(film_id: fully_unseen(user_ids))
      .exclude(film_id: chosen(club))
      .count
  end

  # The same query as Matcher.chosen_film_ids, as a subquery and spelled out
  # here rather than called: lib/matcher.rb requires this file, so the arrow
  # can't point the other way.
  def chosen(club)
    DB[:rounds].where(club_id: club.id).exclude(winning_film_id: nil).select(:winning_film_id)
  end

  def fully_unseen(user_ids)
    DB[:seen_checks]
      .where(user_id: user_ids, seen: false)
      .group(:film_id)
      .having { count(:user_id) >= user_ids.size }
      .select(:film_id)
  end

  # The next films worth asking about: on this club's list, not already ruled
  # out by somebody having seen them, and not already settled for every member.
  #
  # Random order, because the ballot draws at random too — warming the top of
  # the list would verify the films the club is no more likely to be offered
  # than any other.
  def to_check(club, user_ids, limit:)
    return [] if user_ids.empty?

    DB[:club_list_entries]
      .where(club_id: club.id)
      .exclude(film_id: DB[:seen_checks].where(user_id: user_ids, seen: true).select(:film_id))
      .exclude(film_id: fully_unseen(user_ids))
      # No point spending a request on a film the club has already watched.
      .exclude(film_id: chosen(club))
      .order(Sequel.lit("RANDOM()"))
      .limit(limit)
      .select_map(:film_id)
  end

  # film_id => which of these members still owes an answer about it. One query
  # for the whole batch, since the caller works through every film in it.
  def unchecked_users_by_film(film_ids, users)
    return {} if film_ids.empty? || users.empty?

    known = DB[:seen_checks]
            .where(film_id: film_ids, user_id: users.map(&:id))
            .select_map(%i[film_id user_id])
            .group_by(&:first)
            .transform_values { |rows| rows.map(&:last) }

    film_ids.to_h do |film_id|
      answered = known[film_id] || []
      [film_id, users.reject { |u| answered.include?(u.id) }]
    end
  end

  # Has this club got enough verified film in hand to leave it alone tonight?
  def stocked?(club, user_ids)
    verified_unseen_count(club, user_ids) >= club.ballot_size * RESERVE
  end
end
