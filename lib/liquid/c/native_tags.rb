# frozen_string_literal: true

module Liquid
  module C
    module NativeTags
      root = File.join(Gem.loaded_specs.fetch("liquid").full_gem_path, "lib", "liquid")
      specifications = {
        condition: {
          Liquid::If => [:parse_binary_comparisons, :parse_comparison, :parse_expression],
          Liquid::Condition => [:initialize, :and, :or],
          Liquid::Condition.singleton_class => [:parse_expression],
        },
        for: { Liquid::For => [:set_attribute, :parse_expression] },
        expression: { Liquid::Tag => [:parse_expression] },
      }
      GUARDS = specifications.transform_values do |owners|
        owners.flat_map do |owner, names|
          names.map do |name|
            method = owner.instance_method(name)
            standard = method.original_name == name && method.source_location&.first&.start_with?(root + "/")
            [owner, name, method, standard].freeze
          end
        end.freeze
      end.freeze
      CONDITION_CLASS = Liquid::Condition
      CONSTRUCTORS = [:new, :allocate].map { |name| [name, CONDITION_CLASS.method(name)].freeze }.freeze

      class << self
        def compatible?(object, kind)
          GUARDS.fetch(kind).all? do |owner, name, expected, standard|
            standard && owner.instance_method(name) == expected &&
              (kind == :expression || !object.is_a?(owner) || object.method(name).unbind == expected)
          end && (kind != :condition || Liquid::Condition.equal?(CONDITION_CLASS) &&
            CONSTRUCTORS.all? do |name, expected|
              expected.source_location.nil? && expected.owner == Class && expected.original_name == name &&
                CONDITION_CLASS.method(name) == expected
            end)
        end

        def try_tag_header(object, markup, kind)
          result = parse(object, markup, kind)
          return unless result

          context = object.instance_variable_get(:@parse_context)
          payload = NativeParser.commit_tag(context, result, kind)
          [payload]
        end

        def try_case_expression(object, markup)
          return if ENV["LIQUID_C_NATIVE_CASE"] == "false"

          result = parse(object, markup, :expression)
          [NativeParser.commit_tag(object.instance_variable_get(:@parse_context), result, :case)] if result
        end

        def parse(object, markup, kind)
          return if Liquid::C.native_parser_tracing?

          context = object.instance_variable_get(:@parse_context)
          return if ENV["LIQUID_C_NATIVE_TAGS"] == "false" || context.instance_variable_get(:@error_mode) != :strict
          return unless Liquid::C.instance_variable_get(:@enabled)
          return if context.instance_variable_get(:@liquid_c_nodes_disabled)
          return unless Liquid::C.native_frontend_candidate?(markup)
          return unless compatible?(object, kind)

          result = NativeParser.tag_payload(markup, context, kind)
          return unless result && compatible?(object, kind)

          result
        end
      end
    end
  end
end
