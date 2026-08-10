# The forms that put mail in somebody's inbox. There's no password to stuff —
# what's worth stopping is someone holding down /login, or walking a list of
# addresses through it.

require_relative "helper"

class ThrottleTest < BoxdTest
  def test_asking_is_what_spends_the_allowance
    limit = Throttle::LIMITS[:login_email][:limit]

    limit.times { |i| assert Throttle.allow?(:login_email, "a@example.com"), "attempt #{i + 1}" }
    refute Throttle.allow?(:login_email, "a@example.com")
    refute Throttle.allow?(:login_email, "a@example.com")
  end

  def test_one_address_running_out_does_not_stop_another
    Throttle::LIMITS[:login_email][:limit].times { Throttle.allow?(:login_email, "a@example.com") }

    assert Throttle.allow?(:login_email, "b@example.com")
  end

  # Spend the roomier bucket right down, then check the tighter one hasn't been
  # spending out of it. The other way round proves nothing: the tighter limit
  # is still under the roomier one's ceiling.
  def test_the_two_buckets_guarding_a_form_are_counted_apart
    Throttle::LIMITS[:login_ip][:limit].times { Throttle.allow?(:login_ip, "1.2.3.4") }
    refute Throttle.allow?(:login_ip, "1.2.3.4")

    assert Throttle.allow?(:login_email, "1.2.3.4"), "a different bucket, same key"
  end

  def test_the_window_slides
    limit = Throttle::LIMITS[:login_email][:limit]
    per = Throttle::LIMITS[:login_email][:per]
    limit.times { Throttle.allow?(:login_email, "a@example.com") }
    refute Throttle.allow?(:login_email, "a@example.com")

    DB[:rate_limits].update(created_at: Time.now - per - 60)

    assert Throttle.allow?(:login_email, "a@example.com"), "an hour later they can ask again"
  end

  def test_attempts_that_have_aged_out_are_pruned_as_they_go
    Throttle.allow?(:login_email, "a@example.com")
    DB[:rate_limits].update(created_at: Time.now - Throttle::LIMITS[:login_email][:per] - 60)

    Throttle.allow?(:login_email, "a@example.com")

    assert_equal 1, DB[:rate_limits].count, "the dead row should have gone, not piled up"
  end

  def test_the_message_says_how_long_the_window_is
    assert_equal "an hour", Throttle.window_label(:login_email)
  end

  def test_cleanup_sweeps_what_the_windows_left_behind
    Throttle.allow?(:login_ip, "1.2.3.4")
    DB[:rate_limits].update(created_at: Time.now - 86_400 - 60)
    Throttle.allow?(:invite_ip, "1.2.3.4")

    assert_equal 1, Throttle.cleanup!
    assert_equal 1, DB[:rate_limits].count
  end

  def test_an_unknown_bucket_is_a_mistake_worth_raising
    assert_raises(KeyError) { Throttle.allow?(:not_a_bucket, "x") }
  end
end
