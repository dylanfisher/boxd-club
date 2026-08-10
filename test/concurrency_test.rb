# A club has one open round, and a round ends once.
#
# Both are claims about what two callers arriving at the same moment can do —
# two skip votes landing together, two admin buttons pressed at once, the
# scheduler and a web request meeting — so these run real threads against the
# real SQLite file rather than asserting on the shape of the code.
#
# Starting threads together isn't enough to make them collide: the first one
# usually runs to completion before the second is scheduled, and then every
# test here passes whether the guards exist or not. So each test holds its
# threads at a barrier placed just before the critical section — stubbed into a
# method the code calls on its way in — and lets them all go at once. Take the
# guards out and these fail.

require_relative "helper"

class ConcurrencyTest < BoxdTest
  # Well under the pool's max_connections: 5, so a thread blocks on the
  # database rather than on a connection.
  THREADS = 4

  # Releases every waiting thread once `n` of them have arrived. The timeout is
  # what stops a mutated run — where a thread never reaches the barrier —
  # hanging the suite instead of failing it.
  class Barrier
    def initialize(count)
      @count = count
      @arrived = 0
      @mutex = Mutex.new
      @cv = ConditionVariable.new
    end

    def wait(timeout = 5)
      @mutex.synchronize do
        @arrived += 1
        return @cv.broadcast if @arrived >= @count

        @cv.wait(@mutex, timeout)
      end
    end
  end

  def setup
    super
    @a, @b = 2.times.map { user }
    @club = club(members: [@a, @b], ballot_size: 2)
    films(6).each { |f| watchlist(@a, [f]); watchlist(@b, [f]) }
  end

  # Starts `n` threads that all wait, then go at once.
  def race(n = THREADS, &block)
    gate = Queue.new
    threads = n.times.map { |i| Thread.new { gate.pop; block.call(i) } }
    n.times { gate << :go }
    threads.map(&:value)
  end

  # Every caller has chosen its films and is about to open a round. This is the
  # window the immediate transaction and its re-read exist to close.
  def test_two_callers_opening_a_round_together_leave_one_ballot
    barrier = Barrier.new(THREADS)
    picks = Matcher.candidates_for(@club)

    results = stub_method(Matcher, :candidates_for, lambda { |_club, **|
      barrier.wait
      picks
    }) { race { Rounds.open!(@club) } }

    assert_equal 1, @club.rounds_dataset.count
    # A caller that finds a round already going gets handed that one, so what
    # matters is that they all end up looking at the same round...
    assert_equal 1, results.compact.map(&:id).uniq.size
    # ...and that only one of them did the sending.
    assert_equal 2, deliveries.size, "one ballot each, not one per thread"
  end

  # Both members' skip votes are in, and both callers are about to act on them.
  # Counting the calls to open! rather than the rounds left behind: open! has a
  # guard of its own, so the club ends up with one ballot either way — what the
  # claim owns is that only the caller who won it goes on to do the work.
  def test_two_skip_votes_landing_together_end_the_round_once
    round = decided_round
    barrier = Barrier.new(2)
    voters = [@a, @b]

    opens = counting_opens do
      with_barrier_on(Round, :skip_voters, barrier) do
        race(2) { |i| Rounds.skip_vote!(round, voters[i]) }
      end
    end

    assert_equal 1, opens.size, "only the caller that won the claim opens the next round"
    assert_equal "skipped", round.refresh.state
    assert_equal 1, @club.rounds_dataset.where(state: "open").count,
                 "the club should be left with exactly one open round"
    assert_equal 2, @club.rounds_dataset.count
  end

  # Two log checks both find that everyone has logged the winner.
  def test_two_log_checks_finishing_together_open_one_next_round
    round = decided_round
    barrier = Barrier.new(THREADS)
    logged = [@a.letterboxd_username, @b.letterboxd_username]

    opens = counting_opens do
      with_barrier_on(Round, :pending_loggers, barrier) do
        stub_method(Letterboxd, :logged?, ->(username, _slug) { logged.include?(username) }) do
          race { Rounds.check_logs!(round) }
        end
      end
    end

    assert_equal 1, opens.size, "only the caller that won the claim opens the next round"
    assert_equal "watched", round.refresh.state
    assert_equal 1, @club.rounds_dataset.where(state: "open").count
    assert_equal 1, @club.rounds_dataset.where(state: "watched").count
  end

  def test_claiming_a_transition_succeeds_for_exactly_one_caller
    round = decided_round
    barrier = Barrier.new(THREADS)

    won = race do
      barrier.wait
      Rounds.claim!(round, from: "decided", to: "watched", watched_at: Time.now)
    end

    assert_equal 1, won.count(true)
    assert_equal THREADS - 1, won.count(false)
  end

  # The allowance is spent by asking, and two requests arriving together must
  # not both read "2 of 3" and both be let through.
  def test_a_rate_limit_is_not_beaten_by_arriving_at_once
    limit = Throttle::LIMITS[:login_email][:limit]
    barrier = Barrier.new(THREADS)

    allowed = race do
      barrier.wait
      Throttle.allow?(:login_email, "someone@example.com")
    end

    assert_equal [limit, THREADS].min, allowed.count(true)
    assert_equal [limit, THREADS].min, DB[:rate_limits].count
  end

  private

  # Records every call to Rounds.open! made inside the block, and lets each one
  # through to the real thing.
  def counting_opens
    calls = []
    original = Rounds.method(:open!)
    stub_method(Rounds, :open!, lambda { |club, **kwargs|
      calls << club.id
      original.call(club, **kwargs)
    }) { yield }
    calls
  end

  # Holds every caller at `barrier` on their way through an instance method,
  # then lets the real one run. The method has to be one the code calls just
  # before the section under test, or the threads queue up somewhere harmless.
  def with_barrier_on(klass, name, barrier)
    original = klass.instance_method(name)
    klass.define_method(name) do |*args, **kwargs|
      barrier.wait
      original.bind(self).call(*args, **kwargs)
    end
    yield
  ensure
    klass.define_method(name, original)
  end

  def decided_round
    round = Rounds.open!(@club)
    round.candidates.each_with_index.to_h { |c, i| [c.id, i + 1] }.then do |ranking|
      Votes.record_ranking!(round, @a, ranking)
      Votes.record_ranking!(round, @b, ranking)
    end
    Rounds.check_after_vote!(round)
    deliveries.clear
    round.refresh
  end
end
