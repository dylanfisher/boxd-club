Sequel.migration do
  change do
    # One row per attempt at something worth throttling — see lib/throttle.rb.
    # Rows are counted within a window and pruned as they age out, so this
    # table stays small enough that a plain COUNT is the cheapest thing going.
    create_table(:rate_limits) do
      primary_key :id
      # "purpose:key", e.g. "login:email:you@example.com" or "login:ip:1.2.3.4".
      String :bucket, null: false
      Time :created_at, null: false

      index %i[bucket created_at]
    end
  end
end
