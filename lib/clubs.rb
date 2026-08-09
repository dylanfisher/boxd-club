# Creating clubs and moving people in and out of them. Admin-only operations —
# the routes check that, this doesn't.

require_relative "models"
require_relative "letterboxd"

module Clubs
  Invalid = Class.new(StandardError)

  module_function

  def create!(name:, list_mode: "own", list_url: nil, ballot_size: 5, auto_nudge: true)
    name = name.to_s.strip
    raise Invalid, "A club needs a name." if name.empty?

    slug = unique_slug(name)
    club = Club.new(name: name, slug: slug, ballot_size: clamp_ballot_size(ballot_size),
                    auto_nudge: auto_nudge ? true : false)
    apply_mode!(club, list_mode, list_url)
    club.save
    club
  end

  def update!(club, name:, list_mode:, list_url: nil, ballot_size: nil, auto_nudge: nil)
    name = name.to_s.strip
    raise Invalid, "A club needs a name." if name.empty?

    club.name = name
    # nil is "the caller isn't setting this"; the form always sends something,
    # because an unticked checkbox posts nothing on its own.
    club.auto_nudge = auto_nudge ? true : false unless auto_nudge.nil?
    # Blank means "leave it as it was" — the field is one of several on the
    # club form, and clearing it isn't a request to change the ballot.
    club.ballot_size = clamp_ballot_size(ballot_size) unless ballot_size.to_s.strip.empty?
    apply_mode!(club, list_mode, list_url)
    club.save
    club
  end

  # 'list' mode is the only one that needs anything beyond the mode itself, and
  # it's the only one that can be wrong at the point of saving — so it's the
  # only one we go and check.
  def apply_mode!(club, list_mode, list_url)
    mode = list_mode.to_s
    raise Invalid, "Unknown list mode #{mode}." unless Club::MODES.include?(mode)

    club.list_mode = mode

    if mode == "list"
      owner, slug = parse_list_url(list_url)
      raise Invalid, "That doesn't look like a Letterboxd list URL." if owner.nil?

      count = begin
        Letterboxd.check_list(owner, slug)
      rescue Letterboxd::NotFound
        raise Invalid, "No public list at letterboxd.com/#{owner}/list/#{slug}/."
      rescue *Letterboxd::TRANSPORT_ERRORS
        nil # Letterboxd is being cagey. Take the URL and let the fetch sort it out.
      end
      raise Invalid, "That list is empty or private." if count&.zero?

      club.list_owner = owner
      club.list_slug = slug
    else
      club.list_owner = nil
      club.list_slug = nil
    end
  end

  # "https://letterboxd.com/dave/list/top-250/" -> ["dave", "top-250"]
  def parse_list_url(url)
    m = %r{letterboxd\.com/([^/\s]+)/list/([^/\s?#]+)}.match(url.to_s.strip)
    m ? [m[1], m[2]] : [nil, nil]
  end

  def add_member!(club, user)
    Membership.first(club_id: club.id, user_id: user.id) ||
      Membership.create(club_id: club.id, user_id: user.id)
  end

  def remove_member!(club, user)
    Membership.where(club_id: club.id, user_id: user.id).delete
  end

  def member?(club, user)
    return false if user.nil?

    !Membership.first(club_id: club.id, user_id: user.id).nil?
  end

  # The form posts a string, and nothing stops a browser posting one that isn't
  # a number. A typo in an admin field is the admin's mistake to read, not a
  # 500 — so this raises the same Invalid the routes already catch.
  def clamp_ballot_size(size)
    Integer(size.to_s.strip, 10).clamp(2, 10)
  rescue ArgumentError
    raise Invalid, "Ballot size has to be a number between 2 and 10."
  end

  def unique_slug(name)
    base = name.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")
    base = "club" if base.empty?
    return base unless Club.first(slug: base)

    (2..).each do |n|
      candidate = "#{base}-#{n}"
      return candidate unless Club.first(slug: candidate)
    end
  end
end
