# The round lifecycle, per club.
#
#   open      a ballot is out. There is no deadline — the round stays open
#             until every member has voted.
#   decided   the Borda count picked a winner. Everyone with a Letterboxd
#             account now has to watch it and log it.
#   watched   everyone logged it. The next round opens.
#
# Nothing here is on a clock. `advance!` runs often, looks at where each club
# is, and moves it along if it can.

require_relative "models"
require_relative "matcher"
require_relative "seen"
require_relative "tokens"
require_relative "mailer"
require_relative "votes"
require_relative "films"
require_relative "letterboxd"

module Rounds
  # Don't remind people more often than this.
  NUDGE_DAYS = 6
  # Watchlist data older than this is called out on the ballot.
  STALE_DAYS = 8

  # Gap between one member's feed and the next when nobody is watching.
  #
  # Letterboxd::PACE[:background] is the gap between pages of one walk, and
  # that's what this used to borrow — but a log check isn't a walk. It's one
  # request per member, so there's nothing to get through quickly and no reason
  # to look like a crawl arriving in a burst every four hours.
  #
  # Minutes rather than Letterboxd::MEMBER_STAGGER's tens of minutes, because
  # this job comes round six times a night and every club's pending members
  # have to fit inside one pass: at this spacing a hundred of them still finish
  # in under three hours, and a club of eight takes about a quarter of an hour.
  LOG_CHECK_STAGGER = 45.0..180.0

  module_function

  # Builds a round from cached watchlist data and emails the ballots.
  # Does NOT scrape watchlists — the daily fetch does that, so a slow or
  # blocked scrape can't take down ballot generation.
  #
  # deliver: :later sends the ballots on a background thread. The round itself
  # is committed either way — it's only the SMTP round-trips that move off the
  # response path, for the caller who is a member waiting on a page load.
  def open!(club, deliver: :now)
    if (existing = club.current_round)
      warn "[round] club #{club.slug}: round #{existing.id} is #{existing.state}, not opening another"
      return existing
    end

    members = club.voting_members
    if members.size < 2
      warn "[round] club #{club.slug}: need at least 2 members, have #{members.size}"
      return nil
    end

    picks = Matcher.candidates_for(club)
    if picks.empty?
      warn "[round] club #{club.slug}: no eligible films (mode: #{club.list_mode}). " \
           "Watchlists empty, or everything's been seen?"
      return nil
    end

    round = nil
    # `mode: :immediate` takes SQLite's writer lock before the first statement,
    # which is what makes the re-read below a check rather than a guess: two
    # threads that both passed the cheap check at the top would otherwise both
    # see no current round here and both insert, leaving the club with two open
    # rounds and every member with two ballots. Other adapters ignore the option.
    DB.transaction(mode: :immediate) do
      if (existing = club.current_round)
        warn "[round] club #{club.slug}: round #{existing.id} is #{existing.state}, not opening another"
        next
      end

      round = Round.create(
        club_id: club.id, opened_at: Time.now, state: "open",
        number: club.next_round_number
      )
      picks.each_with_index do |p, i|
        Candidate.create(
          round_id: round.id, film_id: p[:film_id],
          position: i + 1, match_count: p[:match_count]
        )
      end
    end
    # Lost the race. The thread that won has already sent the ballots.
    return nil if round.nil?

    # The slow half, and all of it after the round is committed: scraping a
    # film page each for the handful on the ballot, then a mailbox each for the
    # members. Enrichment only fills in director, rating and poster on rows the
    # candidates already point at, so nothing here changes which films are on
    # the ballot — it can travel with the sending, and be lost with it.
    announce = lambda do
      Films.enrich_all!(picks.map { |p| Film[p[:film_id]] })
      send_ballots!(round, members)
    end

    deliver == :later ? in_background(&announce) : announce.call
    round
  end

  # Every club, wherever it happens to be. Safe to run as often as you like.
  # The scheduler passes pace: :background so the log checks trickle; the admin
  # buttons don't, because somebody is watching a page load.
  def advance_all!(pace: :interactive)
    Club.where(active: true).all.shuffle.each { |club| advance!(club, pace: pace) }
  end

  def advance!(club, pace: :interactive)
    round = club.current_round

    # A club's first round is never started by the scheduler. Members are
    # invited before they've all linked a watchlist, and a ballot that goes out
    # the moment two of them have joined is a round the club didn't choose to
    # play. An admin presses "Open a round now" when the club is ready; from
    # then on rounds follow each other on their own.
    return nil if round.nil? && club.never_started?
    return open!(club) if round.nil?

    case round.state
    when "open"    then everyone_voted?(round) ? tally!(round) : maybe_nudge!(round)
    when "decided" then check_logs!(round, pace: pace)
    end
  end

  def everyone_voted?(round) = round.pending_voters.empty?

  # Called straight after a ballot is submitted, so the last vote decides the
  # round immediately instead of waiting for the next scheduler tick.
  #
  # The result emails go out on a background thread: the person who cast the
  # deciding vote shouldn't sit through five SMTP round-trips before their page
  # loads. The decision itself is committed before this returns, so the club
  # page is already correct even if the process dies mid-send.
  def check_after_vote!(round)
    return nil unless round.open? && everyone_voted?(round)

    tally!(round, deliver: :later)
  end

  # Borda count: with n candidates, rank 1 scores n points and rank n scores 1.
  # Favours broadly-liked films over polarising ones, which is what a group
  # watch wants.
  def tally!(round, deliver: :now)
    standings = Votes.standings(round)
    if standings.empty?
      warn "[round] #{round.id} has no votes to tally"
      return nil
    end

    decide!(round, standings.first[:candidate], standings: standings, deliver: deliver)
  end

  # Admin escape hatch: decide a round nobody will finish voting in.
  def force_tally!(round, deliver: :now)
    return tally!(round, deliver: deliver) unless round.votes_dataset.empty?

    decide!(round, round.candidates.sample, random: true, deliver: deliver)
  end

  def decide!(round, candidate, standings: nil, random: false, deliver: :now)
    return warn("[round] #{round.id} has no candidates") if candidate.nil?

    round.update(
      winning_film_id: candidate.film_id,
      state: "decided",
      decided_at: Time.now,
      random_pick: random
    )

    announce = lambda do
      Films.enrich!(Film[candidate.film_id])
      send_results!(round, candidate, standings: standings, random: random)
    end

    deliver == :later ? in_background(&announce) : announce.call
    round
  end

  # A detached thread, because the alternative is making someone wait on SMTP.
  # Anything in here must be safe to lose on a redeploy.
  def in_background(&block)
    Thread.new do
      block.call
    rescue StandardError => e
      warn "[round] background delivery failed: #{e.class}: #{e.message}"
    end
  end

  # Asks Letterboxd who has watched the winner yet. Up to two requests per
  # member who hasn't been seen watching it, so this shrinks as people get to it
  # — and once somebody is recorded we never ask about them again. Unattended,
  # those requests are spread out at LOG_CHECK_STAGGER rather than made back to
  # back.
  def check_logs!(round, pace: :interactive, deliver: :now)
    film = Film[round.winning_film_id]
    return nil if film.nil?

    pending = round.pending_loggers

    if pending.empty? && round.club.linked_members.empty?
      # Nobody in the club has a Letterboxd account, so there's nothing to
      # watch for. An admin closes these by hand.
      warn "[round] #{round.id}: no members with a Letterboxd account — " \
           "mark it watched from the admin page when you're done."
      return nil
    end

    # Shuffled and spaced, so a club of eight doesn't arrive as eight requests
    # in the same second in the same member order every four hours.
    #
    # An unattended run waits before the *first* request too: advance_all!
    # walks every club in one sweep, and without this the next club's first
    # check lands the instant the last one's finished — the gap between members
    # is worth nothing if it doesn't also fall between clubs. An admin pressing
    # a button gets the brisk pace and no opening wait, as everywhere else.
    background = pace == :background
    gap = background ? LOG_CHECK_STAGGER : Letterboxd::PACE.fetch(pace)

    pending.shuffle.each_with_index do |user, i|
      Letterboxd.pause(gap) if background || i.positive?
      how = watched_how(user, film, pace: pace)
      next if how.nil?

      DB[:watch_logs].insert_conflict.insert(
        round_id: round.id, user_id: user.id, detected_at: Time.now
      )
      # Which of the two answered, because they aren't equally good: a run full
      # of `rated` means the fallback is carrying the club, and a member who
      # only ever turns up that way is one whose old films we'd never catch.
      puts "[round] #{round.id}: #{user.letterboxd_username} #{how} #{film.title}"
    rescue *Letterboxd::TRANSPORT_ERRORS => e
      warn "[round] #{round.id}: log check for #{user.letterboxd_username} failed: #{e.class}: #{e.message}"
    end

    return nil unless round.pending_loggers.empty?

    mark_watched!(round, deliver: deliver)
  end

  # Has this member watched the film, and how did we find out? Their feed first,
  # and their films page only if the feed doesn't have it.
  #
  # The feed first because it is the only route Letterboxd leaves open that is
  # ordered by when things were logged rather than by release date, so it
  # answers whatever the film's age — which is the whole point for a club
  # working through a list of classics. It carries about 50 entries, weeks of
  # logging for most people and comfortably longer than the round we're asking
  # about. A yes stops there, so the common case is still one request and the
  # second is only ever spent on somebody we were otherwise about to keep the
  # whole club waiting for.
  #
  # The films page second because a rating is not a diary entry. Rate a film
  # four stars and never log it and the feed never mentions it, while
  # Letterboxd counts it watched and lists it there — so that member used to
  # hold the round open indefinitely, and a club would sit on a film everyone
  # had seen. It's a weaker answer than the feed: release-date ordered and cut
  # off after 72 films, so a member with a long history watching an old film
  # can be genuinely rated and genuinely missing from it. That's survivable
  # here in a way it wouldn't be if this could say no — it can't. A nil is
  # already "nobody has seen them watch it yet", which the next run asks again
  # about, so the page only ever turns a not-yet into a yes.
  #
  # A member with nothing logged at all has no feed, which is a 404. That isn't
  # an answer, only a silence — they may have rated plenty — so it falls
  # through rather than settling for no. Anything else Letterboxd does wrong is
  # left to the caller, which logs it and moves on to the next member: a
  # challenge on the feed doesn't earn a second request against a site that has
  # just refused the first, and the round waits for the next run either way.
  #
  # Returns :logged, :rated, or nil — the first two are the words that end up in
  # the log, so the run says which route closed it.
  def watched_how(user, film, pace: :interactive)
    return :logged if logged?(user, film)

    # The two land back to back against one member, so they get the same gap
    # any two pages of a walk would.
    Letterboxd.pause(Letterboxd::PACE.fetch(pace))
    :rated if rated?(user, film)
  end

  def logged?(user, film)
    Letterboxd.recent_logs(user.letterboxd_username).any? { |e| e[:slug] == film.slug }
  rescue Letterboxd::NotFound
    false
  end

  def rated?(user, film)
    Letterboxd.watched_films(user.letterboxd_username)[:entries]
              .any? { |e| e[:slug] == film.slug }
  rescue Letterboxd::NotFound
    false
  end

  # Claims a state change, for the transitions that end a round and open the
  # next one. Only one caller can win: SQLite serialises writes, so a
  # conditional UPDATE that reports how many rows it touched is a lock, the
  # same one config/schedule.rb uses to stop a redeploy re-firing a job.
  #
  # Worth having because both callers can genuinely arrive twice at once — two
  # `check` threads on the same decided round, or two members' skip votes
  # landing together — and each one goes on to open the next round.
  def claim!(round, from:, to:, **fields)
    return false unless Round.where(id: round.id, state: from).update(state: to, **fields) == 1

    round.refresh
    true
  end

  # Closes a round out and immediately starts the next one.
  def mark_watched!(round, deliver: :now)
    return nil unless claim!(round, from: "decided", to: "watched", watched_at: Time.now)

    puts "[round] #{round.id} watched by everyone — opening the next one"
    open!(round.club, deliver: deliver)
    round
  end

  # A member votes to skip the film this round landed on — it's unavailable, or
  # the club has gone off it. Half the club (rounded up) ends the round.
  #
  # Only a decided round can be skipped: while a ballot is open the way out is
  # to rank it, and a finished round is finished.
  def skip_vote!(round, user, deliver: :now)
    return nil unless round&.decided?

    DB[:skip_votes].insert_conflict.insert(
      round_id: round.id, user_id: user.id, created_at: Time.now
    )
    check_skips!(round, deliver: deliver)
  end

  # A member saying they've watched it, for the times Letterboxd doesn't say so
  # for them. See db/migrate/011 for when that happens.
  #
  # Only for someone the round is actually waiting on. Everybody else is either
  # recorded already or has no Letterboxd account, and a member without one has
  # never been part of what a round waits for — letting them close one here
  # would hand a single person the end of the round, which is the thing
  # skip_vote!'s threshold exists to prevent.
  def log_watch!(round, user, deliver: :now)
    return nil unless round&.decided? && round.pending_loggers.any? { |u| u.id == user.id }

    # insert_conflict, not upsert: a detected log already says everything this
    # one would, and it shouldn't be rewritten into a claim.
    DB[:watch_logs].insert_conflict.insert(
      round_id: round.id, user_id: user.id, detected_at: Time.now, manual: true
    )
    puts "[round] #{round.id}: #{user.display_name} marked #{Film[round.winning_film_id]&.title} watched"
    return nil unless round.pending_loggers.empty?

    mark_watched!(round, deliver: deliver)
  end

  def check_skips!(round, deliver: :now)
    return nil unless round&.decided?

    votes = round.skip_voters.size
    return nil if votes < round.skips_needed

    skip!(round, deliver: deliver)
  end

  # Ends a round without anybody watching the film, and starts the next.
  # The film keeps its place in history and stays spent as far as the matcher
  # is concerned — a film the club voted past shouldn't come back next week.
  def skip!(round, deliver: :now)
    return nil unless claim!(round, from: "decided", to: "skipped", skipped_at: Time.now)

    puts "[round] #{round.id} skipped by vote — opening the next one"
    open!(round.club, deliver: deliver)
    round
  end

  # Puts a club back to the day it was created: no ballot out, no history, and
  # `never_started?` true again — so the scheduler leaves it alone until an
  # admin opens the first round by hand.
  #
  # For the club that started before it was ready. Two of the six members had
  # signed up, so a ballot went out to those two; the rest are still arriving.
  # There's no way to un-send those emails, but there is a way to make the
  # round they point at stop existing, and to stop the club counting a film
  # nobody chose as watched.
  #
  # Members, invites and cached watchlists all stay — the only thing undone is
  # the playing. Candidates, votes, watch logs and skip votes go with the
  # rounds they belong to, on the foreign keys.
  #
  # Returns how many rounds it deleted.
  def reset!(club)
    count = nil
    DB.transaction do
      count = club.rounds_dataset.count
      club.rounds_dataset.delete
    end
    puts "[round] club #{club.slug}: reset — #{count} round#{count == 1 ? '' : 's'} deleted"
    count
  end

  # The automatic chase only. A club with auto_nudge off is never mailed by the
  # scheduler — but the admin button still calls `nudge!` directly, because
  # pressing it is a deliberate act rather than a standing policy.
  def maybe_nudge!(round)
    return nil unless round.club.auto_nudge

    last = round.nudged_at || round.opened_at
    return nil if Time.now - last < NUDGE_DAYS * 86_400

    nudge!(round)
  end

  # Mails everyone who still owes a ballot. `maybe_nudge!` rate-limits this to
  # once every NUDGE_DAYS; the admin button doesn't, because the whole point of
  # pressing it is that the automatic one isn't due yet.
  #
  # Returns the number of people mailed.
  def nudge!(round)
    return 0 unless round&.open?

    pending = round.pending_voters
    return 0 if pending.empty?

    pending.each do |user|
      Mailer.deliver(
        to: user.email, user: user,
        subject: "#{round.club.name} — still waiting on your ballot (#{round.label.downcase})",
        template: "nudge",
        club: round.club, round: round,
        candidates: round.candidate_films,
        waiting_on: pending.size,
        club_url: club_url(round.club, user)
      )
    rescue StandardError => e
      warn "[round] nudge to #{user.email} failed: #{e.class}: #{e.message}"
    end

    round.update(nudged_at: Time.now)
    puts "[round] #{round.id}: nudged #{pending.size} #{pending.size == 1 ? 'person' : 'people'}"
    pending.size
  end

  # Prints what a ballot would look like. Built for tuning the matcher.
  def dry_run!(club)
    members = club.voting_members
    puts "#{club.name} (#{club.slug}) — mode: #{club.list_mode}"
    puts "members: #{members.size}"
    members.each do |u|
      puts format("  %-30s %-18s %4d films%s", u.email, u.letterboxd_username || "(no account)",
                  u.watchlist_size,
                  club.list_mode == "list" ? format(", %d watched", Seen.user_count(u.id)) : "")
    end

    if club.list_mode == "list"
      user_ids = members.select(&:linked?).map(&:id)
      list_size = DB[:club_list_entries].where(club_id: club.id).count
      puts "\nlist: #{list_size} films, #{Seen.watched_on_list_count(club, user_ids)} already watched by somebody"
    end

    picks = Matcher.candidates_for(club)
    if picks.empty?
      puts "\nno eligible films."
      return
    end

    chosen = Matcher.chosen_film_ids(club)
    seen = Matcher.last_seen(club).keys - chosen
    puts "\nheld back: #{chosen.size} already chosen (never return), " \
         "#{seen.size} already on a ballot (return once the pool is exhausted)"
    puts "\nballot:"
    picks.each_with_index do |p, i|
      film = Film[p[:film_id]]
      puts format("  %d. %-60s %d/%d want it", i + 1, film.display, p[:match_count], members.size)
    end
  end

  # Members whose data the ballot leans on but we haven't read lately — the
  # caveat at the foot of the ballot email.
  #
  # Which data that is depends on the mode. The three watchlist modes build a
  # ballot out of watchlists; a list club builds one out of its list, minus
  # what people have already watched, and never fetches a watchlist at all —
  # so asking about watchlist freshness there called every member stale on
  # every ballot.
  def stale_usernames(club, members)
    return [] if members.empty?
    return unknown_history_usernames(members) unless club.watchlist_mode?

    cutoff = Time.now - (STALE_DAYS * 86_400)
    # Compared in SQL: SQLite's max() aggregate returns an untyped string, so
    # doing this in Ruby means comparing a String to a Time.
    fresh = DB[:watchlist_entries]
            .where(user_id: members.map(&:id))
            .where { fetched_at >= cutoff }
            .distinct
            .select_map(:user_id)
    members.select(&:linked?).reject { |u| fresh.include?(u.id) }.map(&:letterboxd_username)
  end

  # List mode's equivalent: members we have no watch history for at all, so
  # nothing they've seen was filtered out of their ballot. Nothing ever writes
  # a "no" (see lib/seen.rb), so an empty record is the only signal there is.
  def unknown_history_usernames(members)
    linked = members.select(&:linked?)
    return [] if linked.empty?

    known = DB[:seen_checks].where(user_id: linked.map(&:id), seen: true)
                            .distinct.select_map(:user_id)
    linked.reject { |u| known.include?(u.id) }.map(&:letterboxd_username)
  end

  def send_ballots!(round, members)
    club = round.club
    stale = stale_usernames(club, members)
    candidates = round.candidate_films

    members.each do |user|
      Mailer.deliver(
        to: user.email, user: user,
        subject: "#{club.name} #{round.label.downcase} — rank these #{candidates.size}",
        template: "ballot",
        club: club, round: round,
        candidates: candidates,
        member_count: members.size,
        stale: stale,
        club_url: club_url(club, user)
      )
    rescue StandardError => e
      warn "[round] ballot to #{user.email} failed: #{e.class}: #{e.message}"
    end
    puts "[round] club #{club.slug}: opened round #{round.id}, " \
         "#{candidates.size} candidates, #{members.size} ballots sent"
  end

  def send_results!(round, winner, standings: nil, random: false)
    club = round.club
    film = Film[winner.film_id]

    club.voting_members.each do |user|
      Mailer.deliver(
        to: user.email, user: user,
        subject: "#{club.name} #{round.label.downcase} — we're watching #{film.title}",
        template: "result",
        club: club, round: round, film: film,
        standings: standings, random: random,
        club_url: club_url(club, user)
      )
    rescue StandardError => e
      warn "[round] result to #{user.email} failed: #{e.class}: #{e.message}"
    end
    puts "[round] #{round.id} decided: #{film.display}#{random ? ' (random)' : ''}"
  end

  # Every emailed link is a magic link: it signs the member in and drops them
  # on the club page, where the ballot lives.
  def club_url(club, user)
    Tokens.login_url(user, club.path)
  end
end
