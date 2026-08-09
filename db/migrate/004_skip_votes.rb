# Voting to skip a film.
#
# A decided round waits for everyone to watch the winner, which stalls when the
# film turns out to be unavailable, or nobody actually wants it. Any member can
# vote to skip; once half the voting members have, the round closes unwatched
# and the next one opens.
#
# The threshold is half rounded up, floored at two — 2 of 2, 2 of 3, 2 of 4,
# 3 of 5 — so "everyone skips" and "most people skip" both work, and nobody
# ends a round for the club single-handed. A solo club is the exception: its
# one member is the whole club, so their vote carries.
#
# A skipped round keeps its winning_film_id: it's still what that round chose,
# and the matcher still treats it as spent so the same film isn't offered again
# next week.

Sequel.migration do
  change do
    create_table(:skip_votes) do
      foreign_key :round_id, :rounds, null: false, on_delete: :cascade
      foreign_key :user_id, :users, null: false, on_delete: :cascade
      Time :created_at, null: false

      primary_key %i[round_id user_id]
    end

    alter_table(:rounds) do
      # Set instead of watched_at when a round ends by vote rather than by
      # everyone logging the film. State becomes 'skipped'.
      add_column :skipped_at, Time
    end
  end
end
