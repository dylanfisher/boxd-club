# Creating clubs and moving people in and out of them. The admin form posts
# strings, and nothing stops a browser posting one that isn't a number — a typo
# in an admin field should be a message to read, not a 500.

require_relative "helper"

class ClubsTest < BoxdTest
  def test_a_club_gets_a_slug_from_its_name
    assert_equal "thursday-club", Clubs.create!(name: "Thursday Club").slug
    assert_equal "the-90s", Clubs.create!(name: "  The '90s!  ").slug
  end

  def test_two_clubs_with_the_same_name_get_different_slugs
    slugs = 3.times.map { Clubs.create!(name: "Film Club").slug }

    assert_equal %w[film-club film-club-2 film-club-3], slugs
  end

  def test_a_name_with_nothing_usable_in_it_still_gets_a_slug
    assert_equal "club", Clubs.create!(name: "!!!").slug
  end

  def test_a_club_needs_a_name
    assert_raises(Clubs::Invalid) { Clubs.create!(name: "   ") }
    assert_raises(Clubs::Invalid) { Clubs.create!(name: nil) }
  end

  def test_ballot_size_is_clamped_to_something_a_person_can_rank
    assert_equal 2, Clubs.create!(name: "a", ballot_size: 1).ballot_size
    assert_equal 10, Clubs.create!(name: "b", ballot_size: 500).ballot_size
    assert_equal 5, Clubs.create!(name: "c", ballot_size: "5").ballot_size
  end

  def test_a_ballot_size_that_is_not_a_number_is_a_message_not_a_crash
    error = assert_raises(Clubs::Invalid) { Clubs.create!(name: "a", ballot_size: "five") }

    assert_match(/number between 2 and 10/, error.message)
  end

  def test_an_unknown_mode_is_refused
    assert_raises(Clubs::Invalid) { Clubs.create!(name: "a", list_mode: "vibes") }
  end

  # -- list mode -------------------------------------------------------------

  def test_a_list_url_is_read_for_its_owner_and_slug
    assert_equal %w[dave top-250], Clubs.parse_list_url("https://letterboxd.com/dave/list/top-250/")
    assert_equal %w[dave top-250], Clubs.parse_list_url("letterboxd.com/dave/list/top-250/detail/page/2/")
    assert_equal %w[dave top-250], Clubs.parse_list_url("https://letterboxd.com/dave/list/top-250?x=1")
    assert_equal [nil, nil], Clubs.parse_list_url("https://letterboxd.com/dave/watchlist/")
    assert_equal [nil, nil], Clubs.parse_list_url("")
  end

  def test_a_list_club_checks_the_list_is_really_there
    club = stub_method(Letterboxd, :check_list, ->(_owner, _slug) { 42 }) do
      Clubs.create!(name: "Top 250", list_mode: "list",
                    list_url: "https://letterboxd.com/dave/list/top-250/")
    end

    assert_equal "dave", club.list_owner
    assert_equal "top-250", club.list_slug
    assert_equal "https://letterboxd.com/dave/list/top-250/", club.list_url
  end

  def test_a_list_mode_club_with_no_list_url_is_refused
    assert_raises(Clubs::Invalid) { Clubs.create!(name: "a", list_mode: "list", list_url: "nonsense") }
  end

  def test_a_list_that_is_not_there_is_refused
    stub_method(Letterboxd, :check_list, ->(*) { raise Letterboxd::NotFound, "404" }) do
      error = assert_raises(Clubs::Invalid) do
        Clubs.create!(name: "a", list_mode: "list", list_url: "https://letterboxd.com/dave/list/gone/")
      end
      assert_match(%r{dave/list/gone}, error.message)
    end
  end

  def test_an_empty_or_private_list_is_refused
    stub_method(Letterboxd, :check_list, ->(*) { 0 }) do
      assert_raises(Clubs::Invalid) do
        Clubs.create!(name: "a", list_mode: "list", list_url: "https://letterboxd.com/dave/list/x/")
      end
    end
  end

  # Letterboxd being unreachable isn't a reason to refuse an admin's URL — the
  # nightly fetch will find out soon enough.
  def test_letterboxd_being_unreachable_does_not_block_the_club
    club = stub_method(Letterboxd, :check_list, ->(*) { raise Letterboxd::RateLimited, "challenge" }) do
      Clubs.create!(name: "a", list_mode: "list", list_url: "https://letterboxd.com/dave/list/x/")
    end

    assert_equal "dave", club.list_owner
  end

  def test_moving_a_club_off_a_list_forgets_the_list
    club = stub_method(Letterboxd, :check_list, ->(*) { 42 }) do
      Clubs.create!(name: "a", list_mode: "list", list_url: "https://letterboxd.com/dave/list/x/")
    end

    Clubs.update!(club, name: "a", list_mode: "own")

    assert_nil club.refresh.list_owner
    assert_nil club.list_slug
    assert_nil club.list_url
  end

  # -- updating --------------------------------------------------------------

  def test_leaving_the_ballot_size_field_blank_leaves_it_alone
    club = Clubs.create!(name: "a", ballot_size: 7)

    Clubs.update!(club, name: "a", list_mode: "own", ballot_size: "")

    assert_equal 7, club.refresh.ballot_size
  end

  # An unticked checkbox posts nothing at all, so "off" arrives as a missing
  # parameter rather than a false.
  def test_an_unticked_nudge_box_turns_the_nudge_off
    club = Clubs.create!(name: "a")
    assert club.auto_nudge

    Clubs.update!(club, name: "a", list_mode: "own", auto_nudge: nil)
    assert club.refresh.auto_nudge, "nil means the caller isn't setting this"

    Clubs.update!(club, name: "a", list_mode: "own", auto_nudge: false)
    refute club.refresh.auto_nudge
  end

  # -- membership ------------------------------------------------------------

  def test_adding_the_same_member_twice_does_not_duplicate_them
    club = Clubs.create!(name: "a")
    member = user

    Clubs.add_member!(club, member)
    Clubs.add_member!(club, member)

    assert_equal 1, Membership.where(club_id: club.id).count
    assert Clubs.member?(club, member)
  end

  def test_removing_a_member
    club = Clubs.create!(name: "a")
    member = user
    Clubs.add_member!(club, member)

    Clubs.remove_member!(club, member)

    refute Clubs.member?(club, member)
  end

  def test_nobody_is_not_a_member
    refute Clubs.member?(Clubs.create!(name: "a"), nil)
  end
end
