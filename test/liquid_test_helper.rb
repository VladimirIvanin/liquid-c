# frozen_string_literal: true

require_relative "compatibility/boot"
require "minitest/mock"

LIQUID_TEST_DIR = File.join(Gem.loaded_specs.fetch("liquid").full_gem_path, "test")
$LOAD_PATH.unshift(LIQUID_TEST_DIR)
require File.join(LIQUID_TEST_DIR, "test_helper.rb")

# Liquid 5.14.0 hardcodes MRI's older comparison message in these two suites.
require File.join(LIQUID_TEST_DIR, "integration/blank_body_error_handling_test")
require File.join(LIQUID_TEST_DIR, "integration/error_handling_test")

module UpstreamComparisonErrorExpectation
  COMPARISON_MESSAGE = begin
    5 > "x"
  rescue ArgumentError => error
    error.message
  end

  def assert_equal(expected, actual, *args)
    case expected
    when "Liquid error (line 1): comparison of Integer with String failed"
      expected = "Liquid error (line 1): #{COMPARISON_MESSAGE}"
    when "Liquid error: comparison of Integer with String failed0"
      expected = "Liquid error: #{COMPARISON_MESSAGE}0"
    end
    super(expected, actual, *args)
  end
end

BlankBodyErrorHandlingTest.prepend(UpstreamComparisonErrorExpectation)
ErrorHandlingTest.prepend(UpstreamComparisonErrorExpectation)
