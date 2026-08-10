Sequel.migration do
  change do
    # Whether a member has already watched a film, one row per answer we got
    # from Letterboxd. Only clubs in 'list' mode need this: a watchlist is by
    # definition films you haven't seen, so the other three modes filter
    # themselves. See lib/seen.rb.
    create_table(:seen_checks) do
      foreign_key :user_id, :users, null: false, on_delete: :cascade
      foreign_key :film_id, :films, null: false, on_delete: :cascade
      # False rows matter as much as true ones: they're what stops us asking
      # Letterboxd the same question every night for a 500-film list.
      TrueClass :seen, null: false
      Time :checked_at, null: false

      primary_key %i[user_id film_id]
      # The matcher's question is per film across a club's members.
      index :film_id
      index %i[user_id seen]
    end
  end
end
