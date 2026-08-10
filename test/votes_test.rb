# Ranked ballots and the Borda tally. The ballot form is a public URL, so most
# of this is about what a hand-made POST can't do.

require_relative "helper"

class VotesTest < BoxdTest
  def setup
    super
    @a, @b, @c = 3.times.map { user }
    @club = club(members: [@a, @b, @c], ballot_size: 3)
    @films = films(3)
    @round = round(@club, @films)
    @x, @y, @z = @round.candidates
  end

  def rank(*candidates) = candidates.each_with_index.to_h { |c, i| [c.id, i + 1] }

  # -- what a ballot has to be -----------------------------------------------

  def test_a_complete_ranking_is_saved
    Votes.record_ranking!(@round, @a, rank(@z, @x, @y))

    assert_equal({ @z.id => 1, @x.id => 2, @y.id => 3 }, Votes.ranking_for(@round, @a))
    assert Votes.voted?(@round, @a)
  end

  def test_a_ballot_missing_a_film_is_refused
    assert_raises(Votes::InvalidBallot) { Votes.record_ranking!(@round, @a, rank(@x, @y)) }
    refute Votes.voted?(@round, @a)
  end

  def test_a_ballot_naming_a_film_from_another_round_is_refused
    other = round(club(members: [@a, @b]), films(3))
    intruder = other.candidates.first

    assert_raises(Votes::InvalidBallot) do
      Votes.record_ranking!(@round, @a, { @x.id => 1, @y.id => 2, intruder.id => 3 })
    end
    refute Votes.voted?(@round, @a)
  end

  def test_two_films_in_the_same_position_are_refused
    assert_raises(Votes::InvalidBallot) do
      Votes.record_ranking!(@round, @a, { @x.id => 1, @y.id => 1, @z.id => 2 })
    end
  end

  def test_positions_have_to_start_at_one_and_run_without_gaps
    assert_raises(Votes::InvalidBallot) do
      Votes.record_ranking!(@round, @a, { @x.id => 1, @y.id => 2, @z.id => 9 })
    end
  end

  def test_a_closed_round_takes_no_more_ballots
    @round.update(state: "decided", winning_film_id: @films.first.id)

    assert_raises(Votes::InvalidBallot) { Votes.record_ranking!(@round, @a, rank(@x, @y, @z)) }
  end

  def test_re_ranking_replaces_the_earlier_ballot_rather_than_adding_to_it
    Votes.record_ranking!(@round, @a, rank(@x, @y, @z))
    Votes.record_ranking!(@round, @a, rank(@z, @y, @x))

    assert_equal({ @z.id => 1, @y.id => 2, @x.id => 3 }, Votes.ranking_for(@round, @a))
    assert_equal 3, DB[:votes].where(round_id: @round.id, user_id: @a.id).count
  end

  def test_a_refused_ballot_leaves_the_earlier_one_intact
    Votes.record_ranking!(@round, @a, rank(@x, @y, @z))

    assert_raises(Votes::InvalidBallot) { Votes.record_ranking!(@round, @a, rank(@x, @y)) }
    assert_equal({ @x.id => 1, @y.id => 2, @z.id => 3 }, Votes.ranking_for(@round, @a))
  end

  # -- the tally -------------------------------------------------------------

  # With n candidates, rank 1 scores n and rank n scores 1. The point of Borda
  # is that a film everyone puts second beats one that splits the room.
  def test_borda_scores_a_rank_by_how_many_films_it_beat
    Votes.record_ranking!(@round, @a, rank(@x, @z, @y))
    Votes.record_ranking!(@round, @b, rank(@z, @x, @y))
    Votes.record_ranking!(@round, @c, rank(@z, @x, @y))

    standings = Votes.standings(@round)

    assert_equal [@z.id, @x.id, @y.id], standings.map { |s| s[:candidate].id }
    assert_equal [8, 7, 3], standings.map { |s| s[:points] }
  end

  def test_the_broadly_liked_film_beats_the_polarising_one
    polarising, broad, filler = @x, @y, @z
    Votes.record_ranking!(@round, @a, rank(polarising, broad, filler))
    Votes.record_ranking!(@round, @b, rank(broad, filler, polarising))
    Votes.record_ranking!(@round, @c, rank(broad, filler, polarising))

    standings = Votes.standings(@round)
    winner = standings.first
    polar = standings.find { |s| s[:candidate].id == polarising.id }

    assert_equal broad.id, winner[:candidate].id
    assert_equal 1, polar[:firsts], "the polarising film did take a first place"
    assert_operator winner[:points], :>, polar[:points]
  end

  def test_first_place_counts_are_reported_alongside_points
    Votes.record_ranking!(@round, @a, rank(@x, @y, @z))
    Votes.record_ranking!(@round, @b, rank(@x, @z, @y))

    assert_equal 2, Votes.standings(@round).find { |s| s[:candidate].id == @x.id }[:firsts]
  end

  def test_standings_carry_the_film_for_each_candidate
    Votes.record_ranking!(@round, @a, rank(@x, @y, @z))

    top = Votes.standings(@round).first

    assert_equal @x.film_id, top[:film].id
  end

  def test_a_round_nobody_voted_in_has_no_standings
    assert_empty Votes.standings(@round)
  end

  def test_a_tie_is_broken_at_random_rather_than_by_id
    tallies = 30.times.map do
      DB[:votes].delete
      Votes.record_ranking!(@round, @a, rank(@x, @y, @z))
      Votes.record_ranking!(@round, @b, rank(@z, @y, @x))
      Votes.standings(@round).first[:candidate].id
    end

    assert_operator tallies.uniq.size, :>, 1, "the two tied films should both lead sometimes"
  end

  def test_voter_count_counts_people_not_ballot_rows
    Votes.record_ranking!(@round, @a, rank(@x, @y, @z))
    Votes.record_ranking!(@round, @b, rank(@x, @y, @z))

    assert_equal 2, Votes.voter_count(@round)
  end

  def test_a_signed_out_visitor_has_not_voted
    refute Votes.voted?(@round, nil)
  end
end
