# Formatting shared by every template, so a date looks the same in the app, the
# admin pages and (should they ever carry one) the emails.

module Fmt
  # "August 9, 2026". One house format — don't inline strftime in a template.
  DATE = "%B %-d, %Y"

  module_function

  def date(time) = time&.strftime(DATE)

  # "3 days ago". Always shown beside Fmt.date rather than instead of it: the
  # exact date is the fact, and this is the part you can read without doing
  # arithmetic. Coarse on purpose — nothing here is fresher than a scrape.
  def ago(time)
    return nil if time.nil?

    secs = Time.now - time
    # Rows are written by a background thread and read by a web one, and the
    # database stores UTC — a second of skew shouldn't render "-1 minutes ago".
    return "just now" if secs < 60

    n, unit = case secs
              when 60...3_600 then [secs / 60, "minute"]
              when 3_600...86_400 then [secs / 3_600, "hour"]
              when 86_400...(45 * 86_400) then [secs / 86_400, "day"]
              # The film cache goes back to the first launch and the job table
              # has rows that have never run, so without this last step the
              # bottom of a list reads "670 months ago".
              when (45 * 86_400)...(365 * 86_400) then [secs / (30 * 86_400), "month"]
              else [secs / (365 * 86_400), "year"]
              end
    n = n.floor
    "#{n} #{unit}#{'s' unless n == 1} ago"
  end

  # "1,950". Counts on the cache page run into the thousands, where an
  # undelimited number stops being readable at a glance.
  def number(n) = n.to_i.to_s.reverse.scan(/\d{1,3}/).join(",").reverse
end
