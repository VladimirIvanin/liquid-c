# frozen_string_literal: true

require_relative "../fixtures/liquid_spec/standard_drops"

module Compatibility
  module CorpusFixtures
    class TestDrop < Liquid::Drop
      def initialize(params)
        super()
        @value = params["value"]
      end

      attr_reader :value

      def registers
        { @value => @context.registers[@value] }
      end
    end

    class IntegerDrop < Liquid::Drop
      def initialize(params)
        super()
        @value = params.fetch("value", 0).to_i
      end

      def to_liquid_value
        @value
      end

      def to_s
        @value.to_s
      end

      def ==(other)
        @value == other
      end
    end

    class ValueDrop < Liquid::Drop
      def initialize(value)
        super()
        @value = value
      end

      def to_liquid_value
        @value
      end

      def to_s
        @value.to_s
      end

      def [](key)
        raise Liquid::UndefinedDropMethod, "ValueDrop does not support key access '#{key}'"
      end
    end

    class ToSDrop < Liquid::Drop
      def initialize(params)
        super()
        @params = params
        @calls = 0
      end

      def to_liquid
        @calls += 1
        self
      end

      def to_s
        @params.key?("foo") ? "woot: #{@params["foo"] + @calls}" : @params.fetch("to_s", "").to_s
      end

      def [](_key)
        to_s
      end
    end

    class ThingWithValue < Liquid::Drop
      def initialize(_params)
        super()
      end

      def value
        3
      end
    end

    class SafeBuffer < String
      def html_safe?
        true
      end

      def to_s
        self
      end
    end

    FACTORIES = {
      "BooleanDrop" => ->(params) { StandardBooleanDrop.new(params) },
      "NumberDrop" => ->(params) { StandardNumberDrop.new(params) },
      "StringDrop" => ->(params) { StandardStringDrop.new(params) },
      "MethodDrop" => ->(params) { StandardMethodDrop.new(params) },
      "IndexDrop" => ->(params) { StandardIndexDrop.new(params) },
      "SequenceDrop" => ->(params) { StandardSequenceDrop.new(params) },
      "NilDrop" => ->(params) { StandardNilDrop.new(params) },
      "OpaqueDrop" => ->(params) { StandardOpaqueDrop.new(params) },
      "ErrorDrop" => ->(params) { StandardErrorDrop.new(params) },
      "NestedDrop" => ->(params) { StandardNestedDrop.new(params) },
      "LongString" => ->(params) { "X" * params.fetch("length") },
      "TestDrop" => ->(params) { TestDrop.new(params) },
      "IntegerDrop" => ->(params) { IntegerDrop.new(params) },
      "ValueDrop" => ->(params) { ValueDrop.new(params) },
      "ToSDrop" => ->(params) { ToSDrop.new(params) },
      "ThingWithValue" => ->(params) { ThingWithValue.new(params) },
      "SafeBuffer" => ->(params) { SafeBuffer.new(params.fetch("value", "")) },
    }.freeze

    class << self
      def decode(value, seen = {}.compare_by_identity)
        return seen[value] if seen.key?(value)

        case value
        when Hash
          if value.size == 1 && value.keys.first.is_a?(String) && value.keys.first.start_with?("instantiate:")
            name = value.keys.first.delete_prefix("instantiate:").delete_suffix(":")
            instance = FACTORIES.fetch(name).call(decode(value.values.first, seen))
            seen[value] = instance
            return instance
          end
          copy = {}
          seen[value] = copy
          value.each { |key, entry| copy[decode(key, seen)] = decode(entry, seen) }
          copy
        when Array
          copy = []
          seen[value] = copy
          value.each { |entry| copy << decode(entry, seen) }
          copy
        when String
          if value.start_with?("instantiate:")
            instance = FACTORIES.fetch(value.delete_prefix("instantiate:")).call({})
            seen[value] = instance
            return instance
          end

          seen[value] = value.dup
        else
          value
        end
      end
    end
  end
end
