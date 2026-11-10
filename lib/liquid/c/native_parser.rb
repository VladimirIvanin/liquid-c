# frozen_string_literal: true

require "rbconfig"

module Liquid
  module C
    # Method identities are checked on each operation. Startup-only checks miss
    # application reloads, prepend, singleton methods and direct method changes.
    module NativeParser
      source_root = File.join(Gem.loaded_specs.fetch("liquid").full_gem_path, "lib", "liquid")
      native_source = if RUBY_ENGINE == "truffleruby"
        File.join(RbConfig::CONFIG.fetch("prefix"), "lib/truffle/truffle/cext_ruby.rb")
      end
      native_location = ->(location) { location.nil? || location == native_source }
      specifications = {
        Liquid::Variable => [:ruby_strict_parse, :parse_filterargs, :lax_parse_filter_expressions, :parse_context],
        Liquid::ParseContext => [
          :new_parser,
          :safe_parse_expression,
          :parse_expression,
          :error_mode,
          :liquid_c_nodes_disabled?,
        ],
        Liquid::Parser => [:initialize, :expression, :argument, :variable_lookups, :consume, :consume?, :look, :id?],
        Liquid::VariableLookup => [:initialize],
        Liquid::RangeLookup => [:initialize],
        Liquid::Expression.singleton_class => [:parse, :safe_parse, :inner_parse, :parse_number],
        Liquid::Lexer.singleton_class => [:tokenize],
        Liquid::VariableLookup.singleton_class => [:parse],
        Liquid::RangeLookup.singleton_class => [:parse],
        StringScanner => [:scan, :skip, :pos, :pos=, :peek_byte, :scan_byte, :eos?, :string, :string=],
        Integer => [:to_i],
        Array => [:first, :last],
        Liquid::C.singleton_class => [:enabled],
      }
      GUARDS = specifications.flat_map do |owner, names|
        names.map do |name|
          method = owner.instance_method(name)
          location = method.source_location&.first
          standard = owner == StringScanner ? native_location.call(location) : location&.start_with?(source_root + "/")
          if owner == Integer || owner == Array
            standard = native_location.call(location) || location == "<internal:numeric>" || location == "<internal:array>" ||
              (RUBY_ENGINE == "truffleruby" && location&.start_with?("<internal:core> "))
          end
          if (owner == Liquid::ParseContext && name == :liquid_c_nodes_disabled?) || owner == Liquid::C.singleton_class
            standard = location == File.expand_path("../c.rb", __dir__)
          end
          expected_name = name == :ruby_strict_parse ? :strict_parse : name
          standard &&= method.original_name == expected_name
          standard &&= method.owner == owner if owner == StringScanner
          [owner, name, method, standard].freeze
        end
      end.freeze
      CONTEXT_GUARDS = GUARDS.select { |owner, *| owner == Liquid::ParseContext }.freeze
      CONSTRUCTORS = [Liquid::VariableLookup, Liquid::RangeLookup, Liquid::Parser].flat_map do |klass|
        [:new, :allocate].map { |name| [klass, name, klass.method(name)].freeze }
      end.freeze
      special_tokens = []
      {
        "|" => :PIPE,
        "." => :DOT,
        ":" => :COLON,
        "," => :COMMA,
        "[" => :OPEN_SQUARE,
        "]" => :CLOSE_SQUARE,
        "(" => :OPEN_ROUND,
        ")" => :CLOSE_ROUND,
        "?" => :QUESTION,
        "-" => :DASH,
      }.each do |byte, name|
        special_tokens[byte.ord] = Liquid::Lexer.const_get(name, false)
      end
      CONSTANT_GUARDS = [
        *Liquid::Expression.constants(false).map { |name| [Liquid::Expression, name] },
        *[:Expression, :Lexer, :VariableLookup, :RangeLookup, :Parser, :ParseContext, :Variable].map do |name|
          [Liquid, name]
        end,
        [Liquid, :Const],
        [Liquid::Const, :EMPTY_ARRAY],
        [Liquid, :VariableParser],
        [Liquid::Variable, :JustTagAttributes],
        [Liquid::VariableLookup, :COMMAND_METHODS],
        *Liquid::Lexer.constants(false).map { |name| [Liquid::Lexer, name] },
      ].map do |owner, name|
        pending_autoload = owner.autoload?(name)
        value = pending_autoload ? nil : owner.const_get(name, false)
        source = owner.const_source_location(name)&.first
        mutable_table = owner == Liquid::Lexer && name == :SPECIAL_TABLE
        standard = !pending_autoload && (source&.start_with?(source_root + "/") || source == File.join(
          File.dirname(source_root),
          "liquid.rb",
        )) &&
          (mutable_table ? value == special_tokens : value.is_a?(Module) || value.frozen?)
        [owner, name, value, standard, mutable_table ? value.dup.freeze : nil].freeze
      end.freeze
      GUARD_SPECS = GUARDS.map do |owner, name, *_|
        receiver = if owner == Liquid::ParseContext
          1
        elsif owner == StringScanner
          2
        elsif owner == Liquid::Variable
          3
        else
          0
        end
        [owner, name, receiver, false, nil, nil, ![:initialize, :lax_parse_filter_expressions].include?(name)].freeze
      end.concat(CONSTRUCTORS.map { |klass, name, _| [klass.singleton_class, name, 0, false, nil, nil, true].freeze })
        .concat(CONSTANT_GUARDS.map do |owner, name, value, _standard, snapshot|
                  [owner, name, 0, true, snapshot, value, false].freeze
                end).freeze
      STANDARD_GUARDS = GUARDS.all?(&:last) && CONSTANT_GUARDS.all? { |guard| guard[3] } &&
        CONSTRUCTORS.all? do |_klass, name, method|
          method.source_location.nil? && method.owner == Class && method.original_name == name
        end
      # MRI 3.2's public counter counts registered IC sites. Warm and retain
      # one actual Ruby constant reader per guarded name: changes then invalidate
      # the epoch even when the native parser never executes the Ruby lexer.
      # Method identities and mutable table slots are NOT cached.
      CONSTANT_WATCHERS = if STANDARD_GUARDS && RUBY_ENGINE == "ruby" && RUBY_VERSION.start_with?("3.2.") &&
          Liquid::C.respond_to?(:native_constant_watchers_supported?) &&
          Liquid::C.native_constant_watchers_supported?(RubyVM)
        unchanged = true
        evaluator = Module.instance_method(:module_eval)
        readers = CONSTANT_GUARDS.map do |owner, name, expected, *_|
          reader = evaluator.bind_call(owner, "-> { #{name} }", __FILE__, __LINE__)
          unchanged &&= reader.call.equal?(expected)
          reader.freeze
        end
        unchanged ? readers.freeze : nil
      end
      NATIVE_GUARDS = if Liquid::C.respond_to?(:native_try_parse_variable) && STANDARD_GUARDS && CONSTANT_WATCHERS
        watchers = ENV["LIQUID_C_NATIVE_CONST_CACHE"] == "false" ? nil : CONSTANT_WATCHERS
        Liquid::C.native_parser_register_guards(GUARD_SPECS, watchers, RubyVM)
      else
        false
      end

      class << self
        def parse(markup, context, variable = nil)
          return record(context, :tracing) if Liquid::C.native_parser_tracing?
          return record(context, :disabled) if ENV["LIQUID_C_NATIVE_PARSER"] == "false"
          return record(context, :disabled) unless Liquid::C.instance_variable_get(:@enabled)

          if NATIVE_GUARDS && variable
            result = Liquid::C.native_try_parse_variable(markup, context, variable)
            if result.equal?(false) && compatible?(context, variable)
              result = Liquid::C.native_try_parse_variable(markup, context, variable)
            end
            return result || nil
          end
          return record(context, :disabled) if context.instance_variable_get(:@liquid_c_nodes_disabled)
          return record(context, :hooks) if variable && !variable.instance_of?(Liquid::Variable)
          return record(context, :guard_cost) unless NATIVE_GUARDS || Liquid::C.native_frontend_candidate?(markup)
          return record(context, :hooks) unless compatible?(context, variable)
          return record(context, :disabled) if context.liquid_c_nodes_disabled?
          return record(context, :mode) unless [:lax, :warn, :strict].include?(context.error_mode)

          cache = context.instance_variable_get(:@expression_cache)
          # A caller-supplied cache can execute arbitrary Ruby hooks. Preserve
          # its complete key?/[]/[]= protocol through the original parser.
          return record(context, :cache) unless cache.nil? || cache.equal?(false) || cache.instance_of?(Hash)

          result = Liquid::C.native_parse_variable(markup, cache || nil)
          return record(context, :syntax) unless result
          return record(context, :tracing) if Liquid::C.native_parser_tracing?
          return record(context, :hooks) unless compatible?(context, variable)

          name, filters, pending = result
          Liquid::C.native_publish_cache(cache, pending)
          record(context, :accepted)
          [name, filters]
        end

        def tag_payload(markup, context, kind)
          return if ENV["LIQUID_C_NATIVE_TAGS"] == "false"
          return unless NATIVE_GUARDS || Liquid::C.native_frontend_candidate?(markup)
          return unless compatible?(context)
          return if context.liquid_c_nodes_disabled?
          return unless context.error_mode == :strict && compatible?(context)

          cache = context.instance_variable_get(:@expression_cache)
          return unless cache.nil? || cache.equal?(false) || cache.instance_of?(Hash)

          result = Liquid::C.public_send(:"native_parse_#{kind}", markup, cache || nil)
          return unless result && !Liquid::C.native_parser_tracing? && compatible?(context)

          result
        end

        def commit_tag(context, result, kind)
          payload, pending = result
          cache = context.instance_variable_get(:@expression_cache)
          Liquid::C.native_publish_cache(cache, pending)
          record(context, :"accepted_#{kind}")
          payload
        end

        private

        def compatible?(context, variable = nil)
          return false unless context.instance_of?(Liquid::ParseContext)
          return false unless STANDARD_GUARDS
          return true if NATIVE_GUARDS && Liquid::C.native_parser_methods_compatible?(context, variable)
          return false unless CONSTANT_GUARDS.all? do |owner, name, value, standard, snapshot|
            standard && Liquid::C.native_constant_matches?(owner, name, value, snapshot)
          end
          return false unless GUARDS.all? do |owner, name, method, standard|
                                standard && owner.instance_method(name) == method &&
                                  ([
                                    :initialize,
                                    :lax_parse_filter_expressions,
                                  ].include?(name) || owner.public_method_defined?(name))
                              end
          return false unless CONSTRUCTORS.all? do |klass, name, method|
            klass.singleton_class.public_method_defined?(name) &&
              method.source_location.nil? && klass.method(name) == method
          end

          return false unless CONTEXT_GUARDS.all? do |_owner, name, method, _standard|
                                Liquid::C.native_public_method?(context, name) && context.method(name).unbind == method
                              end

          scanner = context.instance_variable_get(:@string_scanner)
          return false if scanner.frozen?
          return false unless GUARDS.all? do |owner, name, method, _standard|
            target = if owner == StringScanner
              scanner
            elsif owner == Liquid::Variable
              variable
            end
            !target || ([:initialize, :lax_parse_filter_expressions].include?(name) ||
              Liquid::C.native_public_method?(target, name)) && target.method(name).unbind == method
          end

          return true unless NATIVE_GUARDS

          watchers = ENV["LIQUID_C_NATIVE_CONST_CACHE"] == "false" ? nil : CONSTANT_WATCHERS
          Liquid::C.native_parser_register_guards(GUARD_SPECS, watchers, RubyVM)
          Liquid::C.native_parser_methods_compatible?(context, variable)
        end

        def record(context, reason)
          Liquid::C.native_record_stats(context, reason)
        end
      end
    end
  end
end
