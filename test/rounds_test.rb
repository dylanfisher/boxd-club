# The round lifecycle: open → decided → watched, or skipped.
#
# Films are created with details_fetched_at set (see the factory), so opening a
# round doesn't try to enrich them off Letterboxd. Background delivery runs
# inline in tests — test/helper.rb replaces Rounds.in_background.

require_relative "helper"

class RoundsTest < BoxdTest
  def setup
    super
    @a, @b = 2.times.map { user }
    @club = club(members: [@a, @b], ballot_size: 3)
    @films = films(4)
    @films.each { |f| watchlist(@a, [f]); watchlist(@b, [f]) }
  end

  def rank(round, *candidates) = candidates.each_with_index.to_h { |c, i| [c.id, i + 1] }

  # -- opening ---------------------------------------------------------------

  def test_opening_a_round_builds_a_ballot_and_mails_every_member
    round = Rounds.open!(@club)

    assert_equal "open", round.state
    assert_equal 3, round.candidates.size
    assert_equal 1, mail_to(@a.email).size
    assert_equal 1, mail_to(@b.email).size
    assert_match(/rank these 3/, mail_to(@a.email).first.subject)
  end

  def test_the_ballot_email_carries_a_sign_in_link_to_the_club
    Rounds.open!(@club)

    body = body_of(mail_to(@a.email).first)
    token = body[%r{#{Regexp.escape(BASE_URL)}/auth/([A-Za-z0-9_-]+)}, 1]

    refute_nil token, "the ballot should carry a magic link"
    assert_equal @a.id, Tokens.peek(token, "login").user_id
    assert_includes body, "?to=#{@club.path}", "and it should land on the club page"
  end

  def test_a_club_of_one_gets_no_ballot
    solo = club(members: [@a])

    assert_nil Rounds.open!(solo)
    assert_empty deliveries
  end

  def test_a_club_with_nothing_to_offer_gets_no_ballot
    empty = club(members: 2.times.map { user })

    assert_nil Rounds.open!(empty)
    assert_equal 0, empty.rounds_dataset.count
    assert_empty deliveries
  end

  def test_a_club_that_already_has_a_round_going_does_not_get_another
    first = Rounds.open!(@club)

    assert_equal first.id, Rounds.open!(@club).id
    assert_equal 1, @club.rounds_dataset.count
  end

  def test_rounds_are_numbered_per_club_and_never_reused
    first = Rounds.open!(@club)
    other_club = club(members: [@a, @b])

    assert_equal 1, first.number
    assert_equal 1, Rounds.open!(other_club)&.number, "numbering restarts per club"

    first.update(state: "watched", winning_film_id: @films.first.id)
    second = Rounds.open!(@club)
    assert_equal 2, second.number

    # Deleting history leaves a gap rather than renaming what's left.
    first.destroy
    assert_equal 2, second.refresh.number
    assert_equal 3, @club.next_round_number
  end

  # -- deciding --------------------------------------------------------------

  def test_the_last_ballot_in_decides_the_round
    round = Rounds.open!(@club)
    x, y, z = round.candidates

    Votes.record_ranking!(round, @a, rank(round, x, y, z))
    assert_nil Rounds.check_after_vote!(round)
    assert_equal "open", round.refresh.state

    Votes.record_ranking!(round, @b, rank(round, x, z, y))
    Rounds.check_after_vote!(round)

    assert_equal "decided", round.refresh.state
    assert_equal x.film_id, round.winning_film_id
    refute_nil round.decided_at
  end

  def test_deciding_mails_the_result_to_everyone
    round = Rounds.open!(@club)
    deliveries.clear
    x, y, z = round.candidates
    Votes.record_ranking!(round, @a, rank(round, x, y, z))
    Votes.record_ranking!(round, @b, rank(round, x, y, z))
    Rounds.check_after_vote!(round)

    assert_equal 1, mail_to(@a.email).size
    assert_equal 1, mail_to(@b.email).size
    assert_match(/we're watching #{Film[x.film_id].title}/, mail_to(@b.email).first.subject)
  end

  def test_a_round_with_no_votes_at_all_is_not_tallied
    round = Rounds.open!(@club)

    assert_nil Rounds.tally!(round)
    assert_equal "open", round.refresh.state
  end

  def test_forcing_a_tally_with_no_votes_picks_at_random_and_says_so
    round = Rounds.open!(@club)

    Rounds.force_tally!(round)

    assert_equal "decided", round.refresh.state
    assert round.random_pick
    assert_includes round.candidates.map(&:film_id), round.winning_film_id
  end

  def test_forcing_a_tally_with_some_votes_in_respects_them
    round = Rounds.open!(@club)
    x, y, z = round.candidates
    Votes.record_ranking!(round, @a, rank(round, y, x, z))

    Rounds.force_tally!(round)

    assert_equal y.film_id, round.refresh.winning_film_id
    refute round.random_pick
  end

  # -- watching, and the next round ------------------------------------------

  def test_a_round_ends_when_everyone_has_logged_the_winner
    round = decided_round
    stub_logged([@a.letterboxd_username]) do
      Rounds.check_logs!(round)
    end
    assert_equal "decided", round.refresh.state, "one member still owes a log entry"

    stub_logged([@a.letterboxd_username, @b.letterboxd_username]) do
      Rounds.check_logs!(round)
    end

    assert_equal "watched", round.refresh.state
    refute_nil round.watched_at
  end

  def test_the_next_round_opens_by_itself_once_a_round_is_watched
    round = decided_round

    Rounds.mark_watched!(round)

    assert_equal "watched", round.refresh.state
    assert_equal 2, @club.rounds_dataset.count
    assert_equal "open", @club.open_round.state
  end

  def test_a_member_letterboxd_cannot_be_asked_about_is_not_waited_on
    @b.update(letterboxd_username: nil)
    round = decided_round

    stub_logged([@a.letterboxd_username]) do
      Rounds.check_logs!(round)
    end

    assert_equal "watched", round.refresh.state
  end

  def test_letterboxd_falling_over_leaves_the_round_where_it_was
    round = decided_round

    stub_method(Letterboxd, :logged?, ->(*) { raise Letterboxd::RateLimited, "challenge" }) do
      Rounds.check_logs!(round)
    end

    assert_equal "decided", round.refresh.state
  end

  # -- skipping --------------------------------------------------------------

  # Half the club rounded up, never fewer than two, so nobody skips a film for
  # the club alone — except a solo club, which is the whole club by itself.
  def test_how_many_votes_a_skip_takes
    expected = { 1 => 1, 2 => 2, 3 => 2, 4 => 2, 5 => 3, 6 => 3, 7 => 4 }
    members = []

    expected.each do |size, needed|
      members << user while members.size < size
      c = club(members: members)
      assert_equal needed, round(c, films(1), state: "decided").skips_needed,
                   "a club of #{size}"
    end
  end

  def test_one_vote_short_leaves_the_round_alone
    round = decided_round
    Rounds.skip_vote!(round, @a)

    assert_equal "decided", round.refresh.state
    assert_equal 1, round.skip_voters.size
  end

  def test_enough_votes_skip_the_round_and_open_the_next
    round = decided_round
    Rounds.skip_vote!(round, @a)
    Rounds.skip_vote!(round, @b)

    assert_equal "skipped", round.refresh.state
    refute_nil round.skipped_at
    assert_equal "open", @club.open_round&.state
  end

  def test_the_same_member_voting_twice_counts_once
    round = decided_round
    Rounds.skip_vote!(round, @a)
    Rounds.skip_vote!(round, @a)

    assert_equal "decided", round.refresh.state
    assert_equal 1, round.skip_voters.size
  end

  # Exactly as many films as the ballot holds, so the next round has to reach
  # for repeats — and the skipped film is the one it still may not have.
  def test_a_skipped_film_stays_spent
    a, b = 2.times.map { user }
    club = club(members: [a, b], ballot_size: 3)
    films(3).each { |f| watchlist(a, [f]); watchlist(b, [f]) }
    round = Rounds.open!(club)
    ranking = round.candidates.each_with_index.to_h { |c, i| [c.id, i + 1] }
    Votes.record_ranking!(round, a, ranking)
    Votes.record_ranking!(round, b, ranking)
    Rounds.check_after_vote!(round)
    winner = round.refresh.winning_film_id

    Rounds.skip_vote!(round, a)
    Rounds.skip_vote!(round, b)

    next_ballot = club.open_round.candidates.map(&:film_id)
    assert_equal 2, next_ballot.size, "the other two films come back round"
    refute_includes next_ballot, winner
  end

  def test_an_open_round_cannot_be_skipped
    round = Rounds.open!(@club)

    assert_nil Rounds.skip_vote!(round, @a)
    assert_equal 0, DB[:skip_votes].where(round_id: round.id).count
  end

  # -- nudging ---------------------------------------------------------------

  def test_a_nudge_goes_only_to_whoever_still_owes_a_ballot
    round = Rounds.open!(@club)
    x, y, z = round.candidates
    Votes.record_ranking!(round, @a, rank(round, x, y, z))
    deliveries.clear

    assert_equal 1, Rounds.nudge!(round)
    assert_empty mail_to(@a.email)
    assert_equal 1, mail_to(@b.email).size
    refute_nil round.refresh.nudged_at
  end

  def test_the_automatic_nudge_waits_out_its_interval
    round = Rounds.open!(@club)
    deliveries.clear

    assert_nil Rounds.maybe_nudge!(round), "a round that just opened isn't overdue"
    assert_empty deliveries

    round.update(opened_at: Time.now - ((Rounds::NUDGE_DAYS + 1) * 86_400))
    assert_equal 2, Rounds.maybe_nudge!(round)
  end

  def test_a_club_with_the_automatic_nudge_off_is_never_chased_by_itself
    @club.update(auto_nudge: false)
    round = Rounds.open!(@club)
    round.update(opened_at: Time.now - ((Rounds::NUDGE_DAYS + 1) * 86_400))
    deliveries.clear

    assert_nil Rounds.maybe_nudge!(round)
    assert_empty deliveries
    # The admin button calls nudge! directly, and that still works.
    assert_equal 2, Rounds.nudge!(round)
  end

  # A round an admin force-tallied is decided with ballots still outstanding —
  # the one case where "who still owes a ballot" is non-empty on a round that
  # has already been decided, and nobody should be chased for it.
  def test_a_decided_round_is_not_nudged
    round = Rounds.open!(@club)
    Rounds.force_tally!(round)
    deliveries.clear

    assert_equal 2, round.refresh.pending_voters.size
    assert_equal 0, Rounds.nudge!(round)
    assert_empty deliveries
  end

  # -- advance! --------------------------------------------------------------

  def test_advance_opens_a_first_round_tallies_a_full_one_and_leaves_the_rest
    Rounds.advance!(@club)
    round = @club.open_round
    refute_nil round

    Rounds.advance!(@club)
    assert_equal "open", round.refresh.state, "still waiting on ballots"

    x, y, z = round.candidates
    Votes.record_ranking!(round, @a, rank(round, x, y, z))
    Votes.record_ranking!(round, @b, rank(round, x, y, z))
    Rounds.advance!(@club)

    assert_equal "decided", round.refresh.state
  end

  # -- staleness -------------------------------------------------------------

  def test_the_ballot_calls_out_watchlists_we_read_too_long_ago
    stale_user = user
    fresh_user = user
    watchlist(stale_user, [@films.first], fetched_at: Time.now - ((Rounds::STALE_DAYS + 1) * 86_400))
    watchlist(fresh_user, [@films.first])

    assert_equal [stale_user.letterboxd_username],
                 Rounds.stale_usernames([stale_user, fresh_user])
  end

  def test_a_member_with_no_letterboxd_account_is_not_called_stale
    assert_empty Rounds.stale_usernames([user(username: nil)])
  end

  private

  # An open round with the ballots cast, decided the ordinary way.
  def decided_round
    round = Rounds.open!(@club)
    cands = round.candidates
    Votes.record_ranking!(round, @a, rank(round, *cands))
    Votes.record_ranking!(round, @b, rank(round, *cands))
    Rounds.check_after_vote!(round)
    deliveries.clear
    round.refresh
  end
end
