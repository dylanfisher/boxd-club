# Seven rotating SQLite snapshots on the same volume as the database.
#
# Not offsite, so it does nothing for a lost volume — but it covers the failure
# that actually happens, which is a bad migration or a fat-fingered rake task.

require_relative "models"

module Backup
  module_function

  def dir = File.join(APP_ROOT, "db", "backups")

  # `label:` writes to boxd-<label>.db instead of the day-of-week slot, so the
  # pre-migration snapshot doesn't spend one of the seven nightly ones.
  def run!(label: nil)
    path = db_path
    return warn("[backup] not a file-backed database, skipping") if path.nil?

    Dir.mkdir(dir) unless Dir.exist?(dir)
    target = File.join(dir, "boxd-#{label || Time.now.strftime('%a').downcase}.db")

    # VACUUM INTO refuses to overwrite, so clear last week's file first.
    File.unlink(target) if File.exist?(target)
    DB.run("VACUUM INTO '#{target.gsub("'", "''")}'")

    puts "[backup] #{target} (#{File.size(target) / 1024}KB)"
    target
  end

  def db_path
    opts = DB.opts
    return nil unless opts[:adapter].to_s == "sqlite" || opts[:orig_opts]&.dig(:adapter).to_s == "sqlite"

    path = opts[:database].to_s
    path.empty? || path == ":memory:" ? nil : path
  end
end
