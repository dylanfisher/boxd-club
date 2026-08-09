# The one-time "how this works" panel a newly invited member sees.
#
# Members arrive from an invite email with no idea what the site does — they
# get a ballot, rank it, and that's the whole product. The panel explains that
# once, and dismissing it is permanent, so this is a column on the user rather
# than a session flag: dismissing it on a phone must also dismiss it on the
# laptop the next round's email is opened on.
#
# Everyone who already has an account has worked the site out by now, so they
# are backfilled as onboarded and never see it.

Sequel.migration do
  up do
    alter_table(:users) do
      add_column :onboarded_at, Time
    end
    from(:users).update(onboarded_at: Time.now)
  end

  down do
    alter_table(:users) do
      drop_column :onboarded_at
    end
  end
end
