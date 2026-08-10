# The whole suite in one process. `rake test` runs this.

require_relative "helper"

Dir[File.join(__dir__, "*_test.rb")].sort.each { |f| require f }
