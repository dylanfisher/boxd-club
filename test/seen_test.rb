# Which films a club's members have already watched. A single 'yes' drops a
# film for the whole club, and a film nobody has mentioned counts as unseen —
# those two rules are what these check.

require_relative "helper"

class SeenTest < BoxdTest
  def setup
    super
    @a, @b = 2.times.map { user }
    @club = club(mode: "list", members: [@a, @b], ballot_size: 2)
    @films = films(4)
    club_list(@club, @films)
    @ids = [@a.id, @b.id]
  end

  def test_recording_a_batch_twice_leaves_one_row_per_film
    assert_equal 1, Seen.record_seen!(@a.id, [@films[0].id])
    Seen.record_seen!(@a.id, [@films[0].id])

    assert_equal 1, Seen.user_count(@a.id)
    assert_equal 1, DB[:seen_checks].where(user_id: @a.id, film_id: @films[0].id).count,
                 "the row should be updated rather than added to"
  end

  # One member's 'yes' is the bar, not everyone's — the point of the club is
  # watching something together for the first time.
  def test_one_member_having_seen_a_film_is_enough_to_rule_it_out
    Seen.record_seen!(@a.id, [@films[0].id])

    assert_equal [@films[0].id], DB[Seen.watched(@ids).as(:w)].select_map(:film_id)
    assert_equal 1, Seen.watched_on_list_count(@club, @ids)
  end

  def test_a_film_back_on_their_watchlist_is_not_recorded_as_watched
    watchlist(@a, [@films[0]])

    assert_equal 1, Seen.record_seen!(@a.id, [@films[0].id, @films[1].id])
    refute_includes DB[:seen_checks].where(user_id: @a.id, seen: true).select_map(:film_id), @films[0].id
  end

  def test_the_same_film_twice_in_one_batch_is_recorded_once
    assert_equal 1, Seen.record_seen!(@a.id, [@films[0].id, @films[0].id])
  end

  def test_counts_reports_how_many_of_them_have_seen_each_film
    Seen.record_seen!(@a.id, [@films[0].id, @films[1].id])
    Seen.record_seen!(@b.id, [@films[0].id])

    counts = Seen.counts(@ids, @films.map(&:id))

    assert_equal 2, counts[@films[0].id]
    assert_equal 1, counts[@films[1].id]
    assert_nil counts[@films[2].id], "films nobody has seen are absent rather than zero"
  end

  # Per member, for the admin page: whose history is thinning the ballot.
  def test_how_much_of_the_list_each_member_has_watched
    Seen.record_seen!(@a.id, [@films[0].id, @films[1].id])

    counts = Seen.watched_on_list_counts(@club, @ids)

    assert_equal 2, counts[@a.id]
    assert_nil counts[@b.id], "members with none are absent rather than zero"
  end

  # A film off the club's list doesn't count towards it, however many members
  # have watched it.
  def test_films_away_from_the_list_do_not_count_against_it
    off_list = films(1).first
    Seen.record_seen!(@a.id, [off_list.id])

    assert_equal 0, Seen.watched_on_list_count(@club, @ids)
    assert_equal 1, Seen.user_count(@a.id), "it's still part of their history"
  end

  def test_a_club_with_nobody_linked_is_not_asked_about_anything
    assert_equal 0, Seen.watched_on_list_count(@club, [])
    assert_empty Seen.watched_on_list_counts(@club, [])
    assert_empty Seen.counts([], @films.map(&:id))
  end
end
