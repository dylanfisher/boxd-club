Sequel.migration do
  change do
    alter_table(:clubs) do
      # Whether the scheduler chases people who haven't voted. Default on,
      # which is what every club already got; a club that would rather not be
      # mailed between rounds can turn it off without losing the admin's
      # manual "Nudge voters" button.
      add_column :auto_nudge, TrueClass, null: false, default: true
    end
  end
end
