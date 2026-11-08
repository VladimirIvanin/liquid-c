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
          return unless NativeParser::NATIVE_GUARDS || Liquid::C.native_frontend_candidate?(markup)
          return unless compatible?(object, kind)

          result = NativeParser.tag_payload(markup, context, kind)
          return unless result && compatible?(object, kind)

          result
        end
      end

      original_if = Liquid::If.instance_method(:strict_parse)
      if NativeParser::NATIVE_GUARDS && original_if.owner == Liquid::If && original_if.original_name == :strict_parse &&
          original_if.source_location&.first == File.join(root, "tags", "if.rb")
        Liquid::C.native_install_header_parser(original_if, false)
      end

      original_for = Liquid::For.instance_method(:strict_parse)
      if NativeParser::NATIVE_GUARDS && original_for.owner == Liquid::For &&
          original_for.original_name == :strict_parse &&
          original_for.source_location&.first == File.join(root, "tags", "for.rb")
        Liquid::C.native_install_header_parser(original_for, true)
      end

      original_context = Liquid::ParserSwitching.instance_method(:strict_parse_with_error_context)
      if NativeParser::NATIVE_GUARDS && original_context.owner == Liquid::ParserSwitching &&
          original_context.original_name == :strict_parse_with_error_context &&
          original_context.source_location&.first == File.join(root, "parser_switching.rb")
        Liquid::C.native_install_strict_context
      end

      # Case's legacy fragment matcher deliberately remains responsible for
      # choosing the fragment. Its permissive semantics differ from Parser.
      original_case = Liquid::Case.instance_method(:parse_expression)
      if NativeParser::NATIVE_GUARDS && original_case.owner == Liquid::Tag &&
          original_case.original_name == :parse_expression &&
          original_case.source_location&.first == File.join(root, "tag.rb")
        Liquid::C.native_install_case_parser
      end
    end
  end
end
