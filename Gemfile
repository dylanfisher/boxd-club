source "https://rubygems.org"

# The Dockerfile pins ruby:4.0.6-slim. This stays loose so local dev works on
# whatever 4.0.x rbenv has available (ruby-build currently tops out at 4.0.3).
ruby "~> 4.0"

gem "roda"
gem "sequel"
gem "sqlite3"
gem "puma"
gem "rufus-scheduler"
gem "mail"
gem "nokogiri"
# Bundled (not default) since Ruby 3.4, same as ostruct/pstore. Needed by the
# Letterboxd CSV-import backend for correct quoting on titles containing commas.
gem "csv"
gem "erubi"
gem "tilt"
gem "rake"
