# Two bits of artwork the app didn't store before.
#
# users.avatar_*  — a member's Letterboxd profile picture. Letterboxd serves its
#   own avatars from a.ltrbxd.com, which we download and re-serve so a member's
#   face doesn't cost them a request to a third party on every page. Gravatar
#   avatars are the exception: those are already a public CDN built for
#   hotlinking, so we keep the URL and don't copy the bytes.
#
# films.backdrop_url — the wide "fan art" still, shown behind a decided round.
#   Hotlinked like the poster: TMDB's when there's a key, Letterboxd's otherwise.

Sequel.migration do
  change do
    alter_table(:users) do
      # Set only when the avatar is hotlinked (Gravatar); null for a local copy.
      add_column :avatar_url, String
      # Filename under Avatars::DIR when we hold the bytes ourselves.
      add_column :avatar_file, String
      add_column :avatar_fetched_at, Time
    end

    alter_table(:films) do
      add_column :backdrop_url, String
    end
  end
end
