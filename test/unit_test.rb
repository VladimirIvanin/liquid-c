# frozen_string_literal: true

require_relative "compatibility/boot"

$LOAD_PATH.unshift(File.expand_path(__dir__))
Dir[File.join(__dir__, "unit/**/*_test.rb")].sort.each { |path| require path }
