# frozen_string_literal: true

require "yaml"
require "date"
require "digest"
require "json"
require_relative "observation"
require_relative "corpus_fixtures"
require_relative "../fixtures/liquid_spec/time_freezer"

module Compatibility
  module Corpus
    REVISION = "84bf25e0edbca5f7e530574788b0f875ab331f50"
    DIRECTORY = File.expand_path("../fixtures/liquid_spec", __dir__)
    MODES = ["lax", "warn", "strict", "strict2"].freeze
    SHOPIFY_FEATURES = [
      "shopify_filters",
      "shopify_tags",
      "shopify_objects",
      "shopify_blank",
      "shopify_includes",
      "shopify_error_format",
      "shopify_error_handling",
      "shopify_string_access",
      "activesupport",
      "self_environment_shadowing",
      "drop_class_output",
      "strict2_blank_body_errors",
    ].freeze

    class FileSystem
      def initialize(files)
        @files = files
      end

      def read_template_file(name)
        @files.fetch(name) do
          @files.fetch("#{name}.liquid") do
            raise Liquid::FileSystemError, "Could not find asset snippets/#{name}.liquid"
          end
        end
      end
    end

    class << self
      def load_yaml(path)
        YAML.safe_load_file(path, permitted_classes: [Symbol, Date, Time, Range, Regexp], aliases: true)
      end

      def records
        @records ||= load_yaml(File.join(DIRECTORY, "cases.yml"))
      end

      def manifest
        @manifest ||= JSON.parse(File.read(File.join(DIRECTORY, "manifest.json")))
      end

      def observe(record, mode)
        Liquid::Spec::TimeFreezer.freeze_spec_time { observe_with_clock(record, mode) }
      end

      def observe_with_clock(record, mode)
        phase = "parse"
        env = Liquid::Environment.new
        env.error_mode = mode.to_sym
        env.file_system = FileSystem.new(record.fetch("filesystem", {})) if record.key?("filesystem")
        template = Liquid::Template.parse(
          record.fetch("template"),
          environment: env,
          error_mode: mode.to_sym,
          line_numbers: true,
          **record.fetch("options", {}).transform_keys(&:to_sym),
        )
        template.name = record["template_name"] if record["template_name"]
        phase = "render"
        limits = Liquid::ResourceLimits.new(record.fetch("resource_limits", {}).transform_keys(&:to_sym))
        context = Liquid::Context.build(
          environment: env,
          static_environments: CorpusFixtures.decode(record.fetch("environment", {})),
          resource_limits: limits,
          rethrow_errors: !record.fetch("render_errors", false),
          registers: { current_time: Liquid::Spec::TimeFreezer::SPEC_TIME },
        )
        if (renderer = record["exception_renderer"])
          context.exception_renderer = lambda do |error|
            raise error if renderer["raise_internal_errors"] && error.is_a?(Liquid::InternalError)

            error
          end
        end
        output = template.render(context)
        {
          "output" => Observation.normalize(output),
          "errors" => context.errors.map { |error| Observation.error(error) },
          "warnings" => template.warnings.map { |error| Observation.error(error) },
        }
      rescue StandardError, SystemStackError => error
        { "phase" => phase, "exception" => Observation.error(error) }
      end

      def matches?(record, observation)
        errors = record.fetch("errors", {})
        if errors.key?("parse_error") || errors.key?("render_error")
          phase = errors.key?("parse_error") ? "parse" : "render"
          exception = observation["exception"]
          return false unless observation["phase"] == phase && exception

          message = decode_string(exception[:message] || exception["message"])
          klass = exception[:class] || exception["class"]
          return patterns_match?(errors.fetch("#{phase}_error"), "#{klass}: #{message}")
        end
        return false if observation["exception"]

        output = decode_string(observation.fetch("output"))
        return false if record.key?("expected") && output != record["expected"].to_s

        if (pattern = record["expected_pattern"])
          return false unless (pattern.is_a?(Regexp) ? pattern : Regexp.new(pattern)).match?(output)
        end

        patterns_match?(errors.fetch("output", []), output)
      end

      def patterns_match?(patterns, value)
        Array(patterns).all? { |pattern| pattern_match?(pattern, value) }
      end

      def pattern_match?(pattern, value)
        pattern.is_a?(Regexp) ? pattern.match?(value) : value.downcase.include?(pattern.to_s.downcase)
      end

      def decode_string(value)
        Base64.strict_decode64(value.fetch("bytes")).force_encoding(value.fetch("encoding"))
      end

      def digest(path)
        Digest::SHA256.file(path).hexdigest
      end
    end
  end
end
