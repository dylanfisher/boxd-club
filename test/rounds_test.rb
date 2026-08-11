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

    stub_method(Letterboxd, :recent_logs, ->(*) { raise Letterboxd::RateLimited, "challenge" }) do
      Rounds.check_logs!(round)
    end

    assert_equal "decided", round.refresh.state
  end

  # The one route we ask, and the reason it's the only one: the feed is ordered
  # by when things were logged, so it answers for a film of any age.
  def test_the_feed_closes_a_round_everyone_has_logged
    round = decided_round
    film = Film[round.winning_film_id]
    logs = { @a.letterboxd_username => [film.slug], @b.letterboxd_username => [film.slug] }

    stub_recent_logs(logs) do
      Rounds.check_logs!(round)
    end

    assert_equal "watched", round.refresh.state
  end

  # A feed with other films in it is an answer about this one: they haven't
  # watched it, and the round stays open.
  def test_a_feed_without_the_film_holds_the_round_open
    round = decided_round

    stub_recent_logs(@club.linked_members.to_h { |u| [u.letterboxd_username, ["something-else"]] }) do
      Rounds.check_logs!(round)
    end

    assert_equal "decided", round.refresh.state
  end

  # An account with nothing logged at all has no feed — a 404, which means they
  # haven't watched it rather than that anything is broken.
  def test_a_member_with_no_feed_has_not_watched_it
    round = decided_round

    stub_method(Letterboxd, :recent_logs, ->(*) { raise Letterboxd::NotFound, "no feed" }) do
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

  # -- marking it watched by hand ---------------------------------------------

  # The escape hatch for what the feed can't show us: a film ticked watched
  # without a diary entry, or one that fell off the end of a busy week.
  def test_marking_it_watched_records_the_member_and_says_they_said_so
    round = decided_round
    Rounds.log_watch!(round, @a)

    assert_equal [@a.id], round.logged_user_ids
    assert_equal [@b], round.pending_loggers
    assert_equal true, round.watch_log(@a)[:manual]
    assert_equal "decided", round.refresh.state, "the club is still waiting on @b"
  end

  def test_the_last_member_marking_it_watched_closes_the_round
    round = decided_round
    Rounds.log_watch!(round, @a)
    Rounds.log_watch!(round, @b)

    assert_equal "watched", round.refresh.state
    refute_nil round.watched_at
    assert_equal "open", @club.open_round&.state
  end

  # It says what Letterboxd said, not what the member did — a detected log is
  # already the stronger claim and marking it again shouldn't rewrite it.
  def test_marking_it_watched_leaves_a_detected_log_alone
    round = decided_round
    DB[:watch_logs].insert(round_id: round.id, user_id: @a.id, detected_at: Time.now)

    Rounds.log_watch!(round, @a)

    assert_equal false, round.watch_log(@a)[:manual]
  end

  # A member with no Letterboxd account was never part of what the round waits
  # for, so there is nothing here for them to unblock — and recording it would
  # let one person end a round on their own.
  def test_a_member_without_letterboxd_cannot_mark_it_watched
    solo = user(username: nil)
    @club.add_user(solo)
    round = decided_round

    assert_nil Rounds.log_watch!(round, solo)
    assert_empty DB[:watch_logs].where(round_id: round.id, user_id: solo.id).all
  end

  def test_an_open_round_cannot_be_marked_watched
    round = Rounds.open!(@club)

    assert_nil Rounds.log_watch!(round, @a)
    assert_equal 0, DB[:watch_logs].where(round_id: round.id).count
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

  def test_advance_never_starts_a_club_that_has_never_played
    Rounds.advance!(@club)

    assert_nil @club.current_round, "the first round waits on an admin"
  end

  def test_advance_opens_the_next_round_once_a_club_has_history
    first = Rounds.open!(@club)
    Rounds.claim!(first, from: "open", to: "watched", watched_at: Time.now)

    Rounds.advance!(@club)

    refute_nil @club.open_round
  end

  def test_advance_tallies_a_full_round_and_leaves_the_rest
    round = Rounds.open!(@club)

    Rounds.advance!(@club)
    assert_equal "open", round.refresh.state, "still waiting on ballots"

    x, y, z = round.candidates
    Votes.record_ranking!(round, @a, rank(round, x, y, z))
    Votes.record_ranking!(round, @b, rank(round, x, y, z))
    Rounds.advance!(@club)

    assert_equal "decided", round.refresh.state
  end

  # -- reset -----------------------------------------------------------------

  def test_reset_deletes_every_round_and_what_hung_off_it
    round = Rounds.open!(@club)
    Votes.record_ranking!(round, @a, rank(round, *round.candidates))

    assert_equal 1, Rounds.reset!(@club)

    assert_nil @club.current_round
    assert_empty Round.where(club_id: @club.id).all
    assert_empty Candidate.where(round_id: round.id).all
    assert_empty DB[:votes].where(round_id: round.id).all
  end

  def test_a_reset_club_is_back_to_never_having_played_and_waits_for_an_admin
    Rounds.open!(@club)
    Rounds.reset!(@club)

    assert @club.never_started?
    Rounds.advance!(@club)
    assert_nil @club.current_round, "the scheduler leaves a reset club alone"

    assert_equal 1, Rounds.open!(@club).number, "numbering starts over"
  end

  def test_reset_keeps_the_members
    Rounds.open!(@club)
    Rounds.reset!(@club)

    assert_equal 2, @club.voting_members.size
  end

  # -- staleness -------------------------------------------------------------

  def test_the_ballot_calls_out_watchlists_we_read_too_long_ago
    stale_user = user
    fresh_user = user
    watchlist(stale_user, [@films.first], fetched_at: Time.now - ((Rounds::STALE_DAYS + 1) * 86_400))
    watchlist(fresh_user, [@films.first])

    assert_equal [stale_user.letterboxd_username],
                 Rounds.stale_usernames(@club, [stale_user, fresh_user])
  end

  def test_a_member_with_no_letterboxd_account_is_not_called_stale
    assert_empty Rounds.stale_usernames(@club, [user(username: nil)])
  end

  # A list club never reads a watchlist, so watchlist freshness said nothing
  # about its ballot — and called every member stale on every one of them.
  def test_a_list_club_calls_out_members_whose_watch_history_we_dont_have
    known = user
    unknown = user
    list = club(mode: "list", members: [known, unknown], list_owner: "dave", list_slug: "top-500")
    Seen.record_seen!(known.id, [film.id])

    assert_equal [unknown.letterboxd_username], Rounds.stale_usernames(list, [known, unknown])
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
