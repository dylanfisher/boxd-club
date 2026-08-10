# Marking the film watched by hand.
#
# A decided round closes itself: lib/rounds.rb reads each member's Letterboxd
# feed every few hours and records who has logged the winner. The feed is the
# only listing Letterboxd leaves open that is ordered by when things were
# logged rather than by release date, which is why it's the one we read — but
# it carries about fifty entries and only diary entries and reviews. So a
# member who ticks a film watched without logging it, or who gets through fifty
# films before the next check, never appears, and the round sits decided until
# an admin notices.
#
# So: let the member say so themselves. Same row, flagged, because the two are
# not the same claim — one is Letterboxd's word and the other is theirs, and a
# club can reasonably want to tell them apart.

Sequel.migration do
  change do
    alter_table(:watch_logs) do
      add_column :manual, TrueClass, null: false, default: false
    end
  end
end
