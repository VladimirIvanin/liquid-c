# frozen_string_literal: true

require "bigdecimal"
require "cgi"
require "json"

module Compatibility
  module Extensions
    module WhitespaceDefaults
      def initialize(options = Liquid::Const::EMPTY_HASH)
        unless options.key?(:bug_compatible_whitespace_trimming)
          options = options.merge(bug_compatible_whitespace_trimming: true)
        end
        super(options)
      end
    end

    module VariableObserver
      def render(context)
        if context.registers[:observe_variables]
          context["observed_name"] = @markup.split("|", 2).first.strip
          context.registers[:observed_calls] = context.registers.fetch(:observed_calls, 0) + 1
        end
        super
      end
    end

    module ReloadableFilters
      def register_filter(filter)
        @extension_filters ||= []
        previous = @extension_filters.find { |item| item.name == filter.name }
        if previous
          @extension_filters.delete(previous)
          @strainer_template = Class.new(Liquid::StrainerTemplate)
          @strainer_template.add_filter(Liquid::StandardFilters)
          @extension_filters.each { |item| @strainer_template.add_filter(item) }
        end
        super
        @extension_filters << filter
      end
    end

    module DecimalConversion
      def to_number(value)
        case value
        when Float then BigDecimal(value.to_s)
        when Numeric then value
        when String then /\A-?\d+\.\d+\z/.match?(value.strip) ? BigDecimal(value) : value.to_i
        else
          if value.respond_to?(:to_number)
            value.to_number
          elsif value.respond_to?(:to_f)
            BigDecimal(value.to_f.to_s)
          else
            0
          end
        end
      end
    end

    module Filters
      def observed(input)
        "#{@context["observed_name"]}:#{input}"
      end

      def register_value(input)
        "#{input}:#{@context.registers[:scope]}:#{@context.registers.fetch(:missing, "fallback")}"
      end

      def nothing(_input)
        nil
      end

      def safe_markup(input)
        SafeString.new("<b>#{input}</b>")
      end

      def json(input)
        input.to_json
      rescue StandardError
        "{}"
      end

      def collect(input, *values)
        options = values.last.is_a?(Hash) ? values.pop : {}
        [input, *values, options.fetch("label", "none")].join(":")
      end

      def optional_options(input, suffix = "!", options = {})
        "#{input}#{suffix}#{options.fetch("label", "")}"
      end

      def nested_value(input, left, right)
        value = Liquid::Variable.new("inner | append: '!'", Liquid::ParseContext.new).render(@context)
        "#{left}:#{input}:#{value}:#{right}"
      end

      def fail_with(input)
        return input unless @context["fail"]

        case input
        when "argument" then raise ArgumentError, "bad argument"
        when "syntax" then raise Liquid::SyntaxError, "bad syntax"
        when "file" then raise Liquid::FileSystemError, "missing file"
        when "zero" then raise Liquid::ZeroDivisionError, "zero divisor"
        when "float" then raise Liquid::FloatDomainError, "invalid float"
        when "cause"
          begin
            raise FloatDomainError, "Infinity"
          rescue FloatDomainError
            raise Liquid::InternalError, "wrapped float"
          end
        end
      end

      def rendezvous(input)
        @context.registers.fetch(:arrivals) << @context.registers[:scope]
        @context.registers.fetch(:release).pop
        "#{input}:#{@context.registers[:scope]}"
      end
    end

    module Overrides
      def replace(input, pattern, replacement = "")
        return input unless pattern && replacement

        "replace:#{input.to_s.gsub(pattern.to_s, replacement.to_s)}"
      end

      def remove(input, pattern)
        return input unless pattern

        "remove:#{input.to_s.gsub(pattern.to_s, "")}"
      end

      def escape(input)
        "escape:#{CGI.escapeHTML(input.to_s)}" unless input.nil?
      end

      def strip_html(input)
        input.to_s.gsub(%r{<script.*?</script>}m, "").gsub(/<.*?>/m, "").gsub("&nbsp;", " ")
      end

      def round(input, precision = 0)
        Liquid::Utils.to_number(input).to_f.round(precision.to_i)
      end

      def upcase(input)
        "upper:#{input.to_s.upcase}"
      end
    end

    class SafeString < String
      def html_safe?
        true
      end
    end

    class FloatValue
      def to_liquid
        self
      end

      def to_f
        1.25
      end
    end

    class DynamicDrop < Liquid::Drop
      attr_reader :received, :snapshots

      def initialize(values = ["a", "b", "c", "d"])
        super()
        @values = values
        @received = []
        @snapshots = []
      end

      def context=(context)
        super
        @snapshots << [context["preload_limit"], context.registers[:scope]]
      end

      def liquid_method_missing(key)
        @received << key
        case key
        when Integer, Range then @values[key]
        when "title" then "dynamic"
        when "off" then false
        when "absent" then nil
        when "empty" then ""
        end
      end

      def each(&block)
        @values.each(&block)
      end

      def size
        @values.size
      end

      def first
        @values.first
      end

      def last
        @values.last
      end

      def to_s
        "drop-text"
      end

      def to_json(*)
        "{}"
      end
    end

    class BrokenJsonDrop < DynamicDrop
      def to_json(*)
        raise "serialization failed"
      end
    end

    class InspectTag < Liquid::Tag
      def initialize(tag_name, markup, parse_context)
        super
        @variable = Liquid::Variable.new(markup, parse_context)
      end

      def render(context)
        value = @variable.render(context)
        context.registers[:tag_value] = value
        value.is_a?(Liquid::Drop) ? "drop:#{value}" : "other:#{value}"
      end
    end

    class StoreBlock < Liquid::Block
      def render(context)
        context.registers[:store_calls] = context.registers.fetch(:store_calls, 0) + 1
        result = context.stack { super }
        context.instance_variable_set(:@extension_content, result)
        ""
      end

      def block_delimiter
        "end_store"
      end

      def blank?
        true
      end
    end

    class RecallTag < Liquid::Tag
      def render(context)
        context.instance_variable_get(:@extension_content).to_s
      end
    end

    class NonblankBlock < Liquid::Block
      def render(context)
        context.registers[:nonblank_calls] = context.registers.fetch(:nonblank_calls, 0) + 1
        "[#{super}]"
      end

      def blank?
        false
      end
    end

    class SliceBlock < Liquid::Block
      def render(context)
        context.stack do
          context["items"] = context["items"][1..2]
          super
        end
      end
    end

    class NestedTag < Liquid::Tag
      def render(context)
        context.registers.fetch(:nested_template).render!(context)
      end
    end

    class RegisterBlock < Liquid::Block
      def render(context)
        context.stack do
          registers = context.registers
          previous = registers[:scope]
          registers[:scope] = "local"
          begin
            super
          ensure
            registers.delete(:scope)
            registers[:scope] = previous unless registers[:scope] == previous
          end
        end
      end
    end

    class RegisterWriteTag < Liquid::Tag
      def render(context)
        before = context.registers.fetch(:scope)
        context.registers[:scope] = "child"
        "#{before}:#{context.registers[:scope]}"
      end
    end
  end
end
