# Formatting shared by every template, so a date looks the same in the app, the
# admin pages and (should they ever carry one) the emails.

module Fmt
  # "August 9, 2026". One house format — don't inline strftime in a template.
  DATE = "%B %-d, %Y"

  module_function

  def date(time) = time&.strftime(DATE)
end
