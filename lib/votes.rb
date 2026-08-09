# Ranked ballots and the Borda tally.

require_relative "models"

module Votes
  InvalidBallot = Class.new(StandardError)

  module_function

  # Saves a complete ranking. `ranking` maps candidate_id => rank, both as
  # integers, and must cover exactly this round's candidates with exactly the
  # ranks 1..n. Never trust the client's ordering — the form is a public URL.
  #
  # A ballot can be changed while the round is open — re-ranking replaces the
  # earlier one. Once the round is closed it's final: the last ballot in closes
  # the round then and there, so an edit after that could contradict a result
  # that has already been decided and mailed out.
  #
  # The delete and the re-import are one transaction, so an edit can't leave
  # someone with half a ballot or none at all.
  def record_ranking!(round, user, ranking)
    raise InvalidBallot, "this round is closed" unless round.open?

    valid_ids = round.candidates.map(&:id).sort
    given_ids = ranking.keys.map(&:to_i).sort
    ranks = ranking.values.map(&:to_i).sort

    raise InvalidBallot, "ballot doesn't match this round's films" unless given_ids == valid_ids
    raise InvalidBallot, "every film needs a distinct position" unless ranks == (1..valid_ids.size).to_a

    now = Time.now
    DB.transaction do
      DB[:votes].where(round_id: round.id, user_id: user.id).delete
      DB[:votes].import(
        %i[round_id user_id candidate_id rank created_at],
        ranking.map { |cid, rank| [round.id, user.id, cid.to_i, rank.to_i, now] }
      )
    end
  end

  def voted?(round, user)
    return false if user.nil?

    !DB[:votes].where(round_id: round.id, user_id: user.id).empty?
  end

  # This user's ranking as candidate_id => rank, or {} if they haven't voted.
  def ranking_for(round, user)
    DB[:votes].where(round_id: round.id, user_id: user.id)
              .select_hash(:candidate_id, :rank)
  end

  # Borda count. With n candidates, rank 1 scores n points and rank n scores 1.
  # Returns [{ candidate:, film:, points:, firsts: }, ...], best first.
  # Ties break randomly.
  def standings(round)
    candidates = round.candidates
    n = candidates.size
    return [] if n.zero?

    points = DB[:votes].where(round_id: round.id)
                       .group(:candidate_id)
                       .select_hash(:candidate_id, Sequel.function(:sum, n + 1 - Sequel[:rank]).as(:points))
    firsts = DB[:votes].where(round_id: round.id, rank: 1)
                       .group(:candidate_id)
                       .select_hash(:candidate_id, Sequel.function(:count, Sequel[:id]).as(:firsts))

    return [] if points.empty?

    candidates.map { |c|
      { candidate: c, film: Film[c.film_id],
        points: points[c.id].to_i, firsts: firsts[c.id].to_i }
    }.shuffle.sort_by { |r| -r[:points] }
  end

  def voter_count(round)
    # .distinct.count(:user_id) counts rows, not distinct users — each voter
    # has one row per candidate.
    DB[:votes].where(round_id: round.id).select(:user_id).distinct.count
  end
end
