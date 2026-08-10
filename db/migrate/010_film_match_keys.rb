# Films get a match key — normalised title plus year — so the same film reached
# by two routes lands on one row.
#
# The routes disagree about slugs. Scraping gives Letterboxd's own
# (`inception`); watched.csv gives a boxd.it short link that carries no slug at
# all, so lib/letterboxd.rb's importer falls back to one built from the title
# (`inception-2010`). Keying films on slug alone therefore split every imported
# film off into a row of its own, which is how a club ended up with Inception on
# the ballot after a member had imported a history saying they'd watched it: the
# `seen_checks` row and the `club_list_entries` row pointed at different films.
#
# So: add the key, then merge what the old rule split.
#
# The normalisation is inlined rather than called from Film.match_key on
# purpose. A migration has to keep meaning what it meant on the day it ran, and
# lib/models.rb is free to change.
match_key = lambda do |title, year|
  next nil unless year.to_s =~ /\A\d{4}\z/

  base = title.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")
  base.empty? ? nil : "#{base}-#{year}"
end

# Repoints everything that references `loser` at `canonical` and deletes it.
#
# Every one of these tables has a uniqueness constraint the film id is half of,
# so a member who has rows against both films would collide on the update. The
# conflicting rows are dropped first rather than updated into each other —
# portably, since `UPDATE OR IGNORE` is SQLite's alone — which is the right
# answer for all but `seen_checks`, where dropping the loser's row could throw
# away the only 'yes' we have. That one is settled before anything is deleted:
# seen wins over unseen, because the question is whether anybody has watched it.
merge_film = lambda do |db, canonical, loser|
  db[:seen_checks]
    .where(film_id: canonical, seen: false)
    .where(user_id: db[:seen_checks].where(film_id: loser, seen: true).select(:user_id))
    .update(seen: true)

  { seen_checks: :user_id, watchlist_entries: :user_id,
    club_list_entries: :club_id, candidates: :round_id }.each do |table, owner|
    db[table]
      .where(film_id: loser)
      .where(owner => db[table].where(film_id: canonical).select(owner))
      .delete
    db[table].where(film_id: loser).update(film_id: canonical)
  end

  db[:rounds].where(winning_film_id: loser).update(winning_film_id: canonical)
  db[:films].where(id: loser).delete
end

Sequel.migration do
  up do
    add_column :films, :match_key, String
    add_index :films, :match_key

    rows = self[:films].select(:id, :slug, :title, :year).all
    rows.each do |f|
      f[:match_key] = match_key.call(f[:title], f[:year])
      self[:films].where(id: f[:id]).update(match_key: f[:match_key])
    end

    merged = 0
    skipped = []

    rows.group_by { |f| f[:match_key] }.each do |key, group|
      next if key.nil? || group.size < 2

      # The fabricated slug is exactly the match key — that's what the importer
      # built it from — so the real film is the one whose slug is something
      # else. Anything other than one real row and the rest fabricated is not a
      # split we caused, and two genuinely distinct films can share a title and
      # a year, so leave it be and say so.
      real, fabricated = group.partition { |f| f[:slug] != key }
      if real.size != 1
        skipped << "#{key}: #{group.map { |f| f[:slug] }.join(', ')}"
        next
      end

      fabricated.each do |loser|
        merge_film.call(self, real.first[:id], loser[:id])
        merged += 1
      end
    end

    puts "[migrate] films: merged #{merged} duplicate row#{merged == 1 ? '' : 's'}"
    unless skipped.empty?
      warn "[migrate] films: left #{skipped.size} ambiguous group#{skipped.size == 1 ? '' : 's'} alone:"
      skipped.each { |s| warn "[migrate]   #{s}" }
    end
  end

  down do
    drop_column :films, :match_key
  end
end
