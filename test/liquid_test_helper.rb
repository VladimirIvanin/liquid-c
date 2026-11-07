# frozen_string_literal: true

require_relative "compatibility/boot"
require "minitest/mock"

LIQUID_TEST_DIR = File.join(Gem.loaded_specs.fetch("liquid").full_gem_path, "test")
$LOAD_PATH.unshift(LIQUID_TEST_DIR)
require File.join(LIQUID_TEST_DIR, "test_helper.rb")
