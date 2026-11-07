# frozen_string_literal: true

require_relative "liquid_test_helper"

files = Dir[File.join(LIQUID_TEST_DIR, "{unit,integration}/**/*_test.rb")].sort
raise "Missing upstream tests in #{LIQUID_TEST_DIR}" if files.empty?

puts "Upstream: #{files.size} files; #{Compatibility.verify_engine!.inspect}"
files.each { |path| require path }
