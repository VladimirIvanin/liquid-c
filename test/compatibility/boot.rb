# frozen_string_literal: true

require "bundler/setup"

if ENV["COVERAGE"]
  require "simplecov"
  SimpleCov.command_name(ENV.fetch(
    "COVERAGE_NAME",
    "#{ENV.fetch("LIQUID_ENGINE", "c")}-#{ENV.fetch("LIQUID_PARSER_MODE", "strict")}",
  ))
  SimpleCov.coverage_dir("tmp/coverage/ruby")
  SimpleCov.merge_timeout(24 * 60 * 60)
  SimpleCov.start do
    root File.expand_path("../..", __dir__)
    enable_coverage :branch
    track_files "lib/**/*.rb"
    add_filter "/test/"
    add_filter "/tmp/"
  end
end

require "liquid"

module Compatibility
  ROOT = File.expand_path("../..", __dir__)
  ENGINES = ["pure", "c", "no_vm", "disabled"].freeze
  MODES = ["lax", "warn", "strict", "strict2"].freeze
  ENGINE = ENV.fetch("LIQUID_ENGINE") { ENV["LIQUID_C_DISABLE_VM"] ? "no_vm" : "c" }
  MODE = ENV.fetch("LIQUID_PARSER_MODE", "strict").to_sym

  raise ArgumentError, "Unknown engine: #{ENGINE}" unless ENGINES.include?(ENGINE)
  raise ArgumentError, "Unknown parser mode: #{MODE}" unless MODES.include?(MODE.to_s)
  raise "Expected Liquid 5.14.0, got #{Liquid::VERSION}" unless Liquid::VERSION == "5.14.0"

  if ENGINE == "pure" && defined?(Liquid::C) && Liquid::C.constants(false) == [:VERSION]
    Liquid.send(:remove_const, :C)
  end

  unless ENGINE == "pure"
    $LOAD_PATH.unshift(ENV["LIQUID_C_EXTENSION_DIR"]) if ENV["LIQUID_C_EXTENSION_DIR"]
    require "liquid/c"
    Liquid::ParseContext.liquid_c_nodes_disabled = ENGINE == "no_vm"
    Liquid::C.enabled = ENGINE != "disabled"
  end

  Liquid::Environment.default.error_mode = MODE

  class << self
    def verify_engine!
      template = Liquid::Template.parse("{{ value }}", error_mode: :strict)
      native_body = template.root.body.class.name == "Liquid::C::BlockBody"
      native_evaluator = Liquid::Context.instance_method(:evaluate).source_location.nil?
      case ENGINE
      when "pure"
        extension_loaded = $LOADED_FEATURES.any? do |path|
          path.end_with?("/liquid/c.rb", "/liquid_c.so", "/liquid_c.bundle")
        end
        raise "Pure oracle loaded liquid-c" if extension_loaded
        raise "Pure oracle uses native nodes/evaluation" if native_body || native_evaluator
      when "c"
        raise "C nodes/evaluation are inactive" unless native_body && native_evaluator
      when "no_vm"
        raise "Expected Ruby nodes and C evaluator" unless !native_body && native_evaluator
      when "disabled"
        raise "Disabled engine still uses C" if native_body || native_evaluator || Liquid::C.enabled
      end
      {
        engine: ENGINE,
        mode: MODE,
        liquid: Liquid::VERSION,
        ruby: RUBY_DESCRIPTION,
        extension: $LOADED_FEATURES.find { |path| path.end_with?("/liquid_c.so", "/liquid_c.bundle") },
        native_body: native_body,
        native_evaluator: native_evaluator,
      }
    end
  end
end

Compatibility.verify_engine!
GC.stress = true if ENV["GC_STRESS"] == "true"
