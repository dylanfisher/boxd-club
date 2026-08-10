# Everything a test file needs. Require this first and nothing else has to
# think about the environment.
#
# The environment has to be set before config/boot.rb is required, because boot
# connects the database at require time and reads BASE_URL and SESSION_SECRET
# into constants. So this file does that first, then loads the app.
#
# The database is a real SQLite file in a temp directory rather than :memory: —
# `max_connections: 5` means each connection would otherwise get its own
# private empty database, and the round-claiming tests deliberately run two
# threads at once. Boot's own "empty database, create the schema" branch builds
# it, so the suite exercises the same migration path a fresh deploy does.

require "tmpdir"
require "fileutils"

TEST_TMP = File.join(Dir.tmpdir, "boxd-test-#{Process.pid}")
FileUtils.rm_rf(TEST_TMP)
FileUtils.mkdir_p(TEST_TMP)
at_exit { FileUtils.rm_rf(TEST_TMP) }

ENV["RACK_ENV"] = "test"
ENV["DATABASE_URL"] = "sqlite://#{File.join(TEST_TMP, 'test.db')}"
ENV["SESSION_SECRET"] = "t" * 128
ENV["BASE_URL"] = "https://test.boxd.club"
ENV["AVATAR_DIR"] = File.join(TEST_TMP, "avatars")
ENV["ADMIN_EMAILS"] = ""
ENV["MAIL_FROM"] = "Boxd Club <boxd@test.boxd.club>"
# Every deliberate sleep in lib/letterboxd.rb goes through Letterboxd.pause,
# which honours this. Without it the paced crawl tests would really sleep.
ENV["LETTERBOXD_NO_DELAY"] = "1"
ENV.delete("SMTP_HOST")
ENV.delete("TMDB_API_KEY")

require "minitest/autorun"
require "rack/test"

require_relative "../config/boot"
require_relative "../app"

# No test may reach the network. Every outbound request in the app goes through
# Net::HTTP.start (Letterboxd.get, Avatars.fetch, TMDB.get), so refusing it here
# means a test that forgets to stub a scrape fails loudly instead of quietly
# hitting letterboxd.com — or passing on a plane and failing in CI.
#
# NoNetwork::Error descends from StandardError on purpose: the app rescues
# transport failures all over the place, and an escape that a rescue would have
# caught in production must be caught here too.
module NoNetwork
  Error = Class.new(StandardError)

  def start(*args, **kwargs, &block)
    handler = Thread.current[:http_stub]
    return handler.call(*args, **kwargs, &block) if handler

    raise Error, "a test tried to make a real HTTP request — stub the scrape instead"
  end
end
Net::HTTP.singleton_class.prepend(NoNetwork)

MailConfig.stub_for_testing!

# Background delivery runs inline in tests, with the same rescue the real one
# has. Threads that outlive the test would write to a database the next test is
# busy emptying, and "the ballots went out" is exactly what these tests assert.
def Rounds.in_background
  yield
rescue StandardError => e
  warn "[round] background delivery failed: #{e.class}: #{e.message}"
  nil
end

module Factories
  # Children before parents: foreign keys are on, and job_runs is re-seeded
  # rather than emptied because lib/cache.rb reads all three rows.
  TABLES = %i[
    votes candidates watch_logs skip_votes seen_checks rate_limits
    watchlist_entries club_list_entries tokens rounds memberships
    films clubs users
  ].freeze

  module_function

  def reset_db!
    TABLES.each { |t| DB[t].delete }
    DB[:job_runs].delete
    DB[:job_runs].import(%i[name last_run_at],
                         %w[daily_fetch advance cleanup].map { |n| [n, Time.at(0).utc] })
    @seq = 0
  end

  def seq = (@seq = (@seq || 0) + 1)

  # Reachable by default — active, verified, not unsubscribed — because that's
  # what `voting_members` needs and almost every test wants a member who counts.
  def user(email: nil, username: :auto, **rest)
    n = seq
    User.create(
      email: email || "member#{n}@example.com",
      letterboxd_username: username == :auto ? "member#{n}" : username,
      active: true, verified_at: Time.now, onboarded_at: Time.now,
      **rest
    )
  end

  def club(name: nil, mode: "own", members: [], **rest)
    n = seq
    club = Club.create(name: name || "Club #{n}", slug: (name || "club-#{n}").downcase.gsub(/[^a-z0-9]+/, "-"),
                       list_mode: mode, **rest)
    members.each { |u| Membership.create(club_id: club.id, user_id: u.id) }
    club
  end

  # details_fetched_at is set by default so Films.enrich_all! calls a fixture
  # film fresh and doesn't try to scrape it. A test that's about enrichment
  # passes details_fetched_at: nil and stubs the fetch.
  def film(title: nil, **rest)
    n = seq
    Film.create(slug: "film-#{n}", title: title || "Film #{n}", year: 2000 + (n % 25),
                created_at: Time.now, details_fetched_at: Time.now, **rest)
  end

  def films(count) = Array.new(count) { film }

  # Puts films on a member's watchlist.
  def watchlist(user, films, fetched_at: Time.now)
    Array(films).each do |f|
      DB[:watchlist_entries].insert(user_id: user.id, film_id: f.id, fetched_at: fetched_at)
    end
  end

  # Puts films on a club's fixed list, in order.
  def club_list(club, films, fetched_at: Time.now)
    Array(films).each_with_index do |f, i|
      DB[:club_list_entries].insert(club_id: club.id, film_id: f.id, position: i + 1,
                                    fetched_at: fetched_at)
    end
  end

  # A round in whatever state, with candidates, without going through Rounds.
  def round(club, films, state: "open", opened_at: Time.now, **rest)
    r = Round.create(club_id: club.id, opened_at: opened_at, state: state,
                     number: club.next_round_number, **rest)
    Array(films).each_with_index do |f, i|
      Candidate.create(round_id: r.id, film_id: f.id, position: i + 1, match_count: 0)
    end
    r
  end

  # A complete ballot from one member, ranking the round's candidates in the
  # order given (best first).
  def ballot(round, user, candidates)
    Votes.record_ranking!(round, user, candidates.each_with_index.to_h { |c, i| [c.id, i + 1] })
  end
end

class BoxdTest < Minitest::Test
  include Factories

  def setup
    Factories.reset_db!
    Mail::TestMailer.deliveries.clear
    FileUtils.rm_rf(Avatars::DIR)
  end

  # Roda's route_csrf ties a token to one path and method, so a test can't mint
  # its own — it has to read the one the page rendered. Which is worth doing
  # anyway: a form that forgot its token would fail here.
  def csrf_for(page, action)
    get(page)
    form = last_response.body[/<form[^>]*action="#{Regexp.escape(action)}"[^>]*>.*?<\/form>/m]
    raise "no form posting to #{action} on #{page}" if form.nil?

    form[/name="_csrf" value="([^"]+)"/, 1]
  end

  # Signs in the way a member does: by following the magic link out of an email.
  def sign_in(user, to: "/")
    get(URI.parse(Tokens.login_url(user, to)).request_uri)
    follow_redirect! if last_response.redirect?
    user
  end

  # Swaps one method out for the duration of a block, and always puts it back.
  # Minitest 6 dropped Object#stub, and every seam worth stubbing here is a
  # module_function — so redefining the singleton method is both the simplest
  # way and the most faithful one, since that's the method the app calls.
  def stub_method(owner, name, impl)
    original = owner.method(name)
    owner.singleton_class.define_method(name) { |*args, **kw, &blk| impl.call(*args, **kw, &blk) }
    yield
  ensure
    owner.singleton_class.define_method(name, original)
  end

  def deliveries = Mail::TestMailer.deliveries

  # Every message sent to this address, newest last.
  def mail_to(address) = deliveries.select { |m| m.to.include?(address) }

  # The text and HTML parts of a message as one string, for asserting on
  # content without caring which part it landed in.
  def body_of(mail) = mail.parts.map { |p| p.body.decoded }.join("\n")

  # Runs `block` with Letterboxd.get answering from `pages` (a url-fragment =>
  # body hash, or a callable). Anything not covered raises, so a test can't
  # silently pass on markup it never provided.
  def stub_letterboxd(pages)
    responder = lambda do |url|
      if pages.respond_to?(:call)
        pages.call(url)
      else
        _, body = pages.find { |fragment, _| url.include?(fragment.to_s) }
        raise Letterboxd::NotFound, "no such page: #{url}" if body.nil?

        body.is_a?(Proc) ? body.call : body
      end
    end
    stub_method(Letterboxd, :get, responder) { yield }
  end

  # Whether each member has logged a film, from a list of usernames.
  def stub_logged(usernames, &)
    stub_method(Letterboxd, :logged?, ->(username, _slug) { usernames.include?(username) }, &)
  end

  def fixture(name) = File.read(File.join(__dir__, "fixtures", name))

  # A Net::HTTPResponse of the given class, as if it had been read off the wire.
  def http_response(klass, code, body = "", headers = {})
    res = klass.new("1.1", code, "")
    res.instance_variable_set(:@body, body)
    res.instance_variable_set(:@read, true)
    headers.each { |k, v| res[k] = v }
    res
  end

  # Answers every Net::HTTP.start in the block with one response, so the code
  # under test keeps its own request-building and status handling. This is the
  # lowest seam there is — below Letterboxd.get — and it's what the tests about
  # status codes use.
  def stub_http(response)
    fake = Object.new
    fake.define_singleton_method(:request) { |_req| response }
    Thread.current[:http_stub] = ->(*, **, &blk) { blk ? blk.call(fake) : fake }
    yield
  ensure
    Thread.current[:http_stub] = nil
  end
end
