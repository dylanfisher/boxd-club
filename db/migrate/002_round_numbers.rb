# Rounds are numbered per club ("round 5"), so emails and the history can name
# them and a permalink can point at one. Numbering is 1-based per club and
# assigned when the round opens.

Sequel.migration do
  up do
    alter_table(:rounds) do
      add_column :number, Integer
      add_index %i[club_id number]
    end

    # Backfill in the order the rounds actually opened.
    from(:clubs).select_map(:id).each do |club_id|
      from(:rounds).where(club_id: club_id).order(:opened_at, :id).select_map(:id)
                   .each_with_index do |round_id, i|
        from(:rounds).where(id: round_id).update(number: i + 1)
      end
    end
  end

  down do
    alter_table(:rounds) do
      drop_index %i[club_id number]
      drop_column :number
    end
  end
end
