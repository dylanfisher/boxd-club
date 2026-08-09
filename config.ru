require_relative "app"

# The scheduler runs in-process, in the same Puma process serving requests.
# Loaded only when explicitly enabled, so rake tasks and local dev never arm cron.
require_relative "config/schedule" if ENV["ENABLE_SCHEDULER"] == "1"

run App.freeze.app
