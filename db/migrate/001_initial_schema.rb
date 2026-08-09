Sequel.migration do
  change do
    create_table(:users) do
      primary_key :id
      String :email, null: false, unique: true
      String :letterboxd_username
      # Site-wide admin: can create clubs, invite people, force rounds.
      TrueClass :admin, null: false, default: false
      Time :verified_at
      TrueClass :active, null: false, default: false
      Time :unsubscribed_at
      Time :created_at
      Time :updated_at
    end

    create_table(:clubs) do
      primary_key :id
      String :name, null: false
      String :slug, null: false, unique: true
      # How candidates are chosen:
      #   own   — every member's own watchlist, ranked by how many share a film
      #   cross — only films on *every* member's watchlist
      #   union — every film on any member's watchlist, unranked
      #   list  — one fixed Letterboxd list (list_owner + list_slug)
      String :list_mode, null: false, default: "own"
      String :list_owner
      String :list_slug
      Integer :ballot_size, null: false, default: 5
      TrueClass :active, null: false, default: true
      Time :created_at
      Time :updated_at
    end

    create_table(:memberships) do
      primary_key :id
      foreign_key :club_id, :clubs, null: false, on_delete: :cascade
      foreign_key :user_id, :users, null: false, on_delete: :cascade
      Time :created_at

      unique %i[club_id user_id]
      index :user_id
    end

    create_table(:tokens) do
      primary_key :id
      foreign_key :user_id, :users, null: false, on_delete: :cascade
      # 'verify' | 'login' | 'vote' | 'unsub'
      String :purpose, null: false
      # SHA256 of the token. The raw token is never stored.
      String :token_hash, null: false, unique: true
      Time :expires_at
      Time :used_at
      Time :created_at

      index %i[user_id purpose]
    end

    create_table(:films) do
      primary_key :id
      String :slug, null: false, unique: true
      String :title, null: false
      Integer :year
      String :director
      # Letterboxd's weighted average, 0.5–5.0.
      Float :rating
      Integer :tmdb_id
      # Hotlinked from image.tmdb.org when we have a TMDB id, otherwise from
      # Letterboxd's own CDN (a.ltrbxd.com), which serves posters fine.
      String :poster_url
      # Null until the film page has been scraped for the fields above.
      Time :details_fetched_at
      Time :created_at
    end

    create_table(:watchlist_entries) do
      foreign_key :user_id, :users, null: false, on_delete: :cascade
      foreign_key :film_id, :films, null: false, on_delete: :cascade
      Time :fetched_at, null: false

      primary_key %i[user_id film_id]
      index :film_id
    end

    # Only used by clubs in 'list' mode.
    create_table(:club_list_entries) do
      foreign_key :club_id, :clubs, null: false, on_delete: :cascade
      foreign_key :film_id, :films, null: false, on_delete: :cascade
      Integer :position
      Time :fetched_at, null: false

      primary_key %i[club_id film_id]
      index :film_id
    end

    create_table(:rounds) do
      primary_key :id
      foreign_key :club_id, :clubs, null: false, on_delete: :cascade
      # Rounds have no deadline. They stay open until every member has voted.
      Time :opened_at, null: false
      # 'open'     — collecting ballots
      # 'decided'  — winner picked, waiting for everyone to log it
      # 'watched'  — everyone with a Letterboxd account has logged it
      String :state, null: false, default: "open"
      foreign_key :winning_film_id, :films
      TrueClass :random_pick, null: false, default: false
      Time :decided_at
      Time :watched_at
      # Throttles the "still waiting on you" reminders.
      Time :nudged_at
      Time :created_at

      index %i[club_id state]
      index :winning_film_id
    end

    create_table(:candidates) do
      primary_key :id
      foreign_key :round_id, :rounds, null: false, on_delete: :cascade
      foreign_key :film_id, :films, null: false, on_delete: :cascade
      Integer :position, null: false
      Integer :match_count, null: false, default: 0

      unique %i[round_id film_id]
      # The rotation rule ("candidate 3+ times in 28 days") queries by film.
      index :film_id
    end

    create_table(:votes) do
      primary_key :id
      foreign_key :round_id, :rounds, null: false, on_delete: :cascade
      foreign_key :user_id, :users, null: false, on_delete: :cascade
      foreign_key :candidate_id, :candidates, null: false, on_delete: :cascade
      # 1 = most wanted.
      Integer :rank, null: false
      Time :created_at

      # Together these make a partial or duplicated ballot impossible to persist.
      unique %i[round_id user_id candidate_id]
      unique %i[round_id user_id rank]
    end

    # One row per member who has logged the winning film on Letterboxd. The
    # next round doesn't open until this covers everyone with a username.
    create_table(:watch_logs) do
      foreign_key :round_id, :rounds, null: false, on_delete: :cascade
      foreign_key :user_id, :users, null: false, on_delete: :cascade
      Time :detected_at, null: false

      primary_key %i[round_id user_id]
    end

    create_table(:job_runs) do
      String :name, primary_key: true
      Time :last_run_at, null: false
    end

    from(:job_runs).import(
      %i[name last_run_at],
      %w[daily_fetch advance cleanup].map { |n| [n, Time.at(0).utc] }
    )
  end
end
