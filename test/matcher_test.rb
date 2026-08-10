# What goes on a ballot. The rules here are the ones the club notices when they
# break — the same five films every week, or a film they already watched.

require_relative "helper"

class MatcherTest < BoxdTest
  def ids(picks) = picks.map { |p| p[:film_id] }

  # -- own -------------------------------------------------------------------

  def test_own_mode_ranks_by_how_many_members_share_a_film
    a, b, c = 3.times.map { user }
    club = club(mode: "own", members: [a, b, c], ballot_size: 3)
    all_three, two, one = films(3)

    watchlist(a, [all_three, two, one])
    watchlist(b, [all_three, two])
    watchlist(c, [all_three])

    picks = Matcher.candidates_for(club)

    assert_equal [all_three.id, two.id], ids(picks).first(2)
    assert_equal [3, 2], picks.first(2).map { |p| p[:match_count] }
  end

  def test_own_mode_backfills_with_single_member_picks
    a, b = 2.times.map { user }
    club = club(mode: "own", members: [a, b], ballot_size: 3)
    shared, a_only, b_only = films(3)

    watchlist(a, [shared, a_only])
    watchlist(b, [shared, b_only])

    picks = Matcher.candidates_for(club)

    assert_equal 3, picks.size
    assert_equal shared.id, ids(picks).first
    assert_equal [a_only.id, b_only.id].sort, ids(picks).drop(1).sort
  end

  # -- cross -----------------------------------------------------------------

  def test_cross_mode_takes_only_films_on_every_watchlist_we_hold
    a, b, never_scraped = 3.times.map { user }
    club = club(mode: "cross", members: [a, b, never_scraped])
    everyones, just_a = films(2)

    watchlist(a, [everyones, just_a])
    watchlist(b, [everyones])
    # never_scraped is linked and in the club but has no watchlist on file: a
    # member we've never read must not empty the intersection for everyone.

    assert_equal [everyones.id], ids(Matcher.candidates_for(club))
  end

  def test_cross_mode_with_no_overlap_produces_no_ballot
    a, b = 2.times.map { user }
    club = club(mode: "cross", members: [a, b])
    just_a, just_b = films(2)

    watchlist(a, [just_a])
    watchlist(b, [just_b])

    assert_empty Matcher.candidates_for(club)
  end

  # -- union -----------------------------------------------------------------

  # Overlap counts for nothing here, which is the whole difference between
  # 'union' and 'own' — and 'own' backfills with single picks too, so a fixture
  # that just checks everything can appear can't tell the two apart. One shared
  # film against twenty solo ones, a ballot of one: 'own' would return the
  # shared film every single time.
  def test_union_mode_ignores_overlap_entirely
    a, b = 2.times.map { user }
    club = club(mode: "union", members: [a, b], ballot_size: 1)
    shared = film
    watchlist(a, [shared])
    watchlist(b, [shared])
    watchlist(a, films(20))

    drawn = 15.times.map { ids(Matcher.candidates_for(club)).first }

    refute_equal [shared.id], drawn.uniq, "a solo pick should turn up in fifteen draws"
  end

  # -- list ------------------------------------------------------------------

  def test_list_mode_drops_films_a_member_has_watched_and_keeps_the_unasked
    a, b = 2.times.map { user }
    # Ballot size 2 against two unwatched films, so the ballot fills from them
    # and the last-resort backfill below never comes into it. The ten watched
    # films are there to make the draw say something: with one watched film the
    # random pick would land on the right answer often enough to pass a broken
    # filter, so the list is mostly films that must never appear, drawn several
    # times over.
    club = club(mode: "list", members: [a, b], ballot_size: 2)
    verified_unseen, never_asked = films(2)
    watched = films(10)
    club_list(club, [*watched, verified_unseen, never_asked])

    watched.each { |f| Seen.record!(user_id: a.id, film_id: f.id, seen: true) }
    Seen.record!(user_id: a.id, film_id: verified_unseen.id, seen: false)
    Seen.record!(user_id: b.id, film_id: verified_unseen.id, seen: false)

    5.times do
      picks = ids(Matcher.candidates_for(club))
      assert_equal [verified_unseen.id, never_asked.id].sort, picks.sort
    end
  end

  def test_list_mode_falls_back_to_the_least_watched_when_everything_is_seen
    a, b = 2.times.map { user }
    club = club(mode: "list", members: [a, b], ballot_size: 2)
    seen_by_both, seen_by_one, also_seen_by_both = films(3)
    club_list(club, [seen_by_both, seen_by_one, also_seen_by_both])

    [seen_by_both, also_seen_by_both].each do |f|
      Seen.record!(user_id: a.id, film_id: f.id, seen: true)
      Seen.record!(user_id: b.id, film_id: f.id, seen: true)
    end
    Seen.record!(user_id: a.id, film_id: seen_by_one.id, seen: true)

    picks = ids(Matcher.candidates_for(club))

    assert_equal 2, picks.size
    assert_equal seen_by_one.id, picks.first, "the film fewest of them have seen should lead"
  end

  # A watchlist is by definition unwatched, so there is nothing for the
  # least-watched fallback to do in the other three modes — and letting it run
  # there would put a film the club has already settled on back on the ballot.
  #
  # A club switched out of 'list' mode keeps the list it had (nothing deletes
  # club_list_entries), so "this club has a list but doesn't draw on one" is a
  # state that really happens, and the fallback has to stay out of it.
  def test_watchlist_modes_send_no_ballot_rather_than_repeat_a_chosen_film
    a, b = 2.times.map { user }
    club = club(mode: "list", members: [a, b], ballot_size: 3)
    chosen, on_the_old_list = films(2)
    club_list(club, [chosen, on_the_old_list])
    Clubs.update!(club, name: club.name, list_mode: "own")

    watchlist(a, [chosen])
    watchlist(b, [chosen])
    round(club, [chosen], state: "watched", winning_film_id: chosen.id)

    assert_empty Matcher.candidates_for(club)
  end

  # -- the two rules on top of the source ------------------------------------

  def test_a_film_the_club_settled_on_never_comes_back
    a, b = 2.times.map { user }
    club = club(mode: "own", members: [a, b], ballot_size: 5)
    watched, skipped, fresh = films(3)
    [watched, skipped, fresh].each { |f| watchlist(a, [f]); watchlist(b, [f]) }

    round(club, [watched], state: "watched", winning_film_id: watched.id)
    round(club, [skipped], state: "skipped", winning_film_id: skipped.id)

    assert_equal [fresh.id], ids(Matcher.candidates_for(club))
  end

  # Losing films share a match_count with the film nobody has been offered, so
  # the tie breaks at random — a ballot of one, drawn repeatedly, is what says
  # the untouched film is preferred rather than merely lucky.
  def test_films_merely_on_a_ballot_wait_for_the_pool_to_run_dry
    a, b = 2.times.map { user }
    club = club(mode: "own", members: [a, b], ballot_size: 1)
    winner, loser, untouched = films(3)
    [winner, loser, untouched].each { |f| watchlist(a, [f]); watchlist(b, [f]) }

    round(club, [winner, loser], state: "watched", winning_film_id: winner.id)

    drawn = 8.times.map { ids(Matcher.candidates_for(club)) }

    assert_equal [[untouched.id]], drawn.uniq,
                 "a film already offered shouldn't come back while an unoffered one is left"
  end

  def test_once_the_pool_is_dry_repeats_return_longest_unseen_first
    a, b = 2.times.map { user }
    club = club(mode: "own", members: [a, b], ballot_size: 2)
    old_winner, old_loser, new_winner, new_loser = films(4)
    [old_winner, old_loser, new_winner, new_loser].each { |f| watchlist(a, [f]); watchlist(b, [f]) }

    round(club, [old_winner, old_loser], state: "watched",
                opened_at: Time.now - (30 * 86_400), winning_film_id: old_winner.id)
    round(club, [new_winner, new_loser], state: "watched",
                opened_at: Time.now - (10 * 86_400), winning_film_id: new_winner.id)

    assert_equal [old_loser.id, new_loser.id], ids(Matcher.candidates_for(club))
  end

  # -- edges -----------------------------------------------------------------

  def test_ballot_never_exceeds_the_clubs_ballot_size
    a, b = 2.times.map { user }
    club = club(mode: "own", members: [a, b], ballot_size: 3)
    films(10).each { |f| watchlist(a, [f]); watchlist(b, [f]) }

    assert_equal 3, Matcher.candidates_for(club).size
  end

  # A list club is the case that matters: its films come from the club's own
  # list rather than from anybody's watchlist, so without this it would happily
  # build a ballot for a club with nobody in it.
  def test_a_club_with_no_members_has_no_ballot
    empty = club(mode: "list")
    club_list(empty, films(3))

    assert_empty Matcher.candidates_for(empty)
    assert_empty Matcher.candidates_for(club(mode: "own"))
  end

  # An unsubscribed member is not a voting member, so their watchlist stops
  # counting towards overlap — otherwise the club keeps being offered films
  # picked for somebody who left.
  def test_only_reachable_members_contribute_a_watchlist
    a = user
    gone = user
    club = club(mode: "own", members: [a, gone], ballot_size: 5)
    shared = film
    watchlist(a, [shared])
    watchlist(gone, [shared])
    gone.update(active: false, unsubscribed_at: Time.now)

    picks = Matcher.candidates_for(club)

    assert_equal [shared.id], ids(picks)
    assert_equal 1, picks.first[:match_count], "the departed member shouldn't still be counted"
  end
end
