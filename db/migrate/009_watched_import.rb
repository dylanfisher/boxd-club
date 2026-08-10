Sequel.migration do
  change do
    alter_table(:users) do
      # When they last uploaded a watched.csv. The seen cache alone can't
      # answer "have you imported your history?" — the nightly fetch puts the
      # 72 most recent films in there for everybody, so a member who has never
      # uploaded anything still has rows. See lib/seen.rb.
      add_column :watched_imported_at, Time
      # And when they dismissed the panel asking them to, so it's asked for
      # once rather than on every page forever.
      add_column :import_dismissed_at, Time
    end
  end
end
