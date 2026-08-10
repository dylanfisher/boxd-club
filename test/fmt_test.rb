# One house format for dates and counts, so nothing has to call strftime in a
# template.

require_relative "helper"

class FmtTest < BoxdTest
  def test_a_date_is_written_one_way
    assert_equal "August 9, 2026", Fmt.date(Time.utc(2026, 8, 9, 12, 0))
    assert_equal "January 1, 2026", Fmt.date(Time.utc(2026, 1, 1)), "no leading zero on the day"
    assert_nil Fmt.date(nil)
  end

  # Rows are written by a background thread and read by a web one, and the
  # database stores UTC — a second of skew shouldn't render "-1 minutes ago".
  def test_a_moment_ago_reads_as_just_now
    assert_equal "just now", Fmt.ago(Time.now)
    assert_equal "just now", Fmt.ago(Time.now + 5)
    assert_equal "just now", Fmt.ago(Time.now - 59)
  end

  def test_how_long_ago_is_coarse_on_purpose
    {
      90 => "1 minute ago",
      60 * 5 => "5 minutes ago",
      3_600 => "1 hour ago",
      3_600 * 5 => "5 hours ago",
      86_400 => "1 day ago",
      86_400 * 3 => "3 days ago",
      86_400 * 44 => "44 days ago",
      # The film cache goes back to the first launch and the job table has rows
      # that have never run, so without the last two steps the bottom of a list
      # reads "670 months ago".
      86_400 * 60 => "2 months ago",
      86_400 * 300 => "10 months ago",
      86_400 * 400 => "1 year ago",
      86_400 * 900 => "2 years ago"
    }.each do |seconds, expected|
      assert_equal expected, Fmt.ago(Time.now - seconds), "#{seconds}s ago"
    end
  end

  def test_no_time_is_no_answer
    assert_nil Fmt.ago(nil)
  end

  def test_counts_run_into_the_thousands_and_stay_readable
    assert_equal "0", Fmt.number(0)
    assert_equal "999", Fmt.number(999)
    assert_equal "1,950", Fmt.number(1950)
    assert_equal "1,234,567", Fmt.number(1_234_567)
  end
end
