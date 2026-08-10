# Seven rotating SQLite snapshots on the same volume as the database.
#
# Not offsite, so it does nothing for a lost volume — but it covers the failure
# that actually happens, which is a bad migration or a fat-fingered rake task.

require_relative "models"

module Backup
  module_function

  # Beside the database, whatever DATABASE_URL says — *not* a fixed app-relative
  # path. In production the volume is mounted at /app/data, so writing to
  # APP_ROOT/db would put every snapshot inside the container's own filesystem,
  # where the next deploy throws it away. Locally the two are the same directory.
  # nil for a database that isn't a file, the same as db_path — there is nowhere
  # to put snapshots of one, and the caller already has that case to handle.
  def dir(path = db_path) = path && File.join(File.dirname(path), "backups")

  # `label:` writes to boxd-<label>.db instead of the day-of-week slot, so the
  # pre-migration snapshot doesn't spend one of the seven nightly ones.
  def run!(label: nil)
    path = db_path
    return warn("[backup] not a file-backed database, skipping") if path.nil?

    target_dir = dir(path)
    Dir.mkdir(target_dir) unless Dir.exist?(target_dir)
    target = File.join(target_dir, "boxd-#{label || Time.now.strftime('%a').downcase}.db")

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
