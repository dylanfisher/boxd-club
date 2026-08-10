# Which films a club's members have already watched. A single 'yes' drops a
# film for the whole club, and a film nobody has been asked about counts as
# unseen — those two rules are what these check.

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

  def test_recording_an_answer_and_changing_it_later
    Seen.record!(user_id: @a.id, film_id: @films[0].id, seen: false)
    assert_equal 0, Seen.user_count(@a.id)

    Seen.record!(user_id: @a.id, film_id: @films[0].id, seen: true)
    assert_equal 1, Seen.user_count(@a.id)
    assert_equal 1, DB[:seen_checks].where(user_id: @a.id, film_id: @films[0].id).count,
                 "the answer should be updated rather than added to"
  end

  # One member's 'yes' is the bar, not everyone's — the point of the club is
  # watching something together for the first time.
  def test_one_member_having_seen_a_film_is_enough_to_rule_it_out
    Seen.record!(user_id: @a.id, film_id: @films[0].id, seen: true)
    Seen.record!(user_id: @b.id, film_id: @films[0].id, seen: false)

    assert_equal [@films[0].id], DB[Seen.watched(@ids).as(:w)].select_map(:film_id)
    assert_equal 1, Seen.watched_on_list_count(@club, @ids)
  end

  def test_bulk_yes_rows_only_ever_promote
    Seen.record!(user_id: @a.id, film_id: @films[0].id, seen: false)

    assert_equal 2, Seen.record_seen!(@a.id, [@films[0].id, @films[1].id])
    assert_equal 2, Seen.user_count(@a.id)
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
    Seen.record!(user_id: @a.id, film_id: @films[0].id, seen: true)
    Seen.record!(user_id: @b.id, film_id: @films[0].id, seen: true)
    Seen.record!(user_id: @a.id, film_id: @films[1].id, seen: true)
    Seen.record!(user_id: @a.id, film_id: @films[2].id, seen: false)

    counts = Seen.counts(@ids, @films.map(&:id))

    assert_equal 2, counts[@films[0].id]
    assert_equal 1, counts[@films[1].id]
    assert_nil counts[@films[2].id], "films nobody has seen are absent rather than zero"
  end

  # A film with one 'no' per member has been asked about everybody and come
  # back clean — a single 'yes' would have taken one of those rows away.
  def test_a_film_counts_as_verified_unseen_only_once_everyone_has_answered
    Seen.record!(user_id: @a.id, film_id: @films[0].id, seen: false)
    assert_equal 0, Seen.verified_unseen_count(@club, @ids), "one member hasn't answered"

    Seen.record!(user_id: @b.id, film_id: @films[0].id, seen: false)
    assert_equal 1, Seen.verified_unseen_count(@club, @ids)
  end

  def test_a_film_the_club_has_settled_on_is_out_of_stock_rather_than_stocked
    @films.each do |f|
      Seen.record!(user_id: @a.id, film_id: f.id, seen: false)
      Seen.record!(user_id: @b.id, film_id: f.id, seen: false)
    end
    assert_equal 4, Seen.verified_unseen_count(@club, @ids)

    round(@club, [@films[0]], state: "watched", winning_film_id: @films[0].id)

    assert_equal 3, Seen.verified_unseen_count(@club, @ids)
  end

  def test_the_films_worth_spending_a_request_on
    seen_by_a, settled, done, fresh = @films
    Seen.record!(user_id: @a.id, film_id: seen_by_a.id, seen: true)
    [@a, @b].each { |u| Seen.record!(user_id: u.id, film_id: settled.id, seen: false) }
    round(@club, [done], state: "watched", winning_film_id: done.id)

    to_check = Seen.to_check(@club, @ids, limit: 10)

    assert_equal [fresh.id], to_check
  end

  def test_who_still_owes_an_answer_about_each_film
    Seen.record!(user_id: @a.id, film_id: @films[0].id, seen: true)

    pending = Seen.unchecked_users_by_film([@films[0].id, @films[1].id], [@a, @b])

    assert_equal [@b.id], pending[@films[0].id].map(&:id)
    assert_equal [@a.id, @b.id].sort, pending[@films[1].id].map(&:id).sort
  end

  # The nightly warm leaves a club alone once it has this much verified film in
  # hand, so a settled club costs nothing most nights.
  def test_a_club_is_left_alone_once_it_has_a_reserve_in_hand
    refute Seen.stocked?(@club, @ids)

    needed = @club.ballot_size * Seen::RESERVE
    extra = films(needed)
    club_list(@club, extra)
    extra.each do |f|
      Seen.record!(user_id: @a.id, film_id: f.id, seen: false)
      Seen.record!(user_id: @b.id, film_id: f.id, seen: false)
    end

    assert Seen.stocked?(@club, @ids)
  end

  def test_a_club_with_nobody_linked_is_not_asked_about_anything
    assert_equal 0, Seen.verified_unseen_count(@club, [])
    assert_equal 0, Seen.watched_on_list_count(@club, [])
    assert_empty Seen.to_check(@club, [], limit: 10)
    assert_empty Seen.counts([], @films.map(&:id))
  end
end
