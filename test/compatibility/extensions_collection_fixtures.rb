# frozen_string_literal: true

module Compatibility
  module Extensions
    module CollectionFilters
      def where_exp(input, binding, expression)
        return input unless input.respond_to?(:select)

        values = input.is_a?(Hash) ? input.values : input
        condition = collection_condition(expression)
        @context.stack do
          values.select do |value|
            @context[binding] = value
            condition.evaluate(@context)
          end
        end
      end

      def find_exp(input, binding, expression)
        return input unless input.respond_to?(:find)

        values = input.is_a?(Hash) ? input.values : input
        condition = collection_condition(expression)
        @context.stack do
          values.find do |value|
            @context[binding] = value
            condition.evaluate(@context)
          end
        end
      end

      def group_by_exp(input, binding, expression)
        return input unless input.respond_to?(:group_by)

        variable = Liquid::Variable.new(expression, Liquid::ParseContext.new)
        groups = @context.stack do
          input.group_by do |value|
            @context[binding] = value
            variable.render(@context)
          end
        end
        groups.map { |name, values| { "name" => name, "items" => values, "size" => values.size } }
      end

      def where(input, property, target)
        return input unless property && input.respond_to?(:select)
        return input if target.is_a?(Array) || target.is_a?(Hash)

        values = input.is_a?(Hash) ? input.values : input
        @collection_cache ||= {}
        key = [values.hash, property, target]
        @collection_cache[key] ||= values.select do |value|
          attribute = property.to_s.split(".").reduce(value.to_liquid) do |object, name|
            object.respond_to?(:[]) && object[name]
          end
          if target.nil?
            attribute.nil?
          elsif target.is_a?(Liquid::Condition::MethodLiteral)
            attribute == target.to_s || Array(attribute).join == target.to_s
          else
            Array(attribute).any? { |item| item.to_s == target.to_s }
          end
        end
      end

      private

      def collection_condition(expression)
        parser = Liquid::Parser.new(expression)
        root = tail = collection_comparison(parser)
        while (relation = parser.id?("and") || parser.id?("or"))
          child = collection_comparison(parser)
          tail.public_send(relation, child)
          tail = child
        end
        parser.consume(:end_of_string)
        root
      end

      def collection_comparison(parser)
        left = Liquid::Expression.parse(parser.expression)
        operator = parser.consume?(:comparison)
        return Liquid::Condition.new(left) unless operator

        right = Liquid::Expression.parse(parser.expression)
        Liquid::Condition.new(left, operator, right)
      end
    end

    class MappingDrop < Liquid::Drop
      include Enumerable

      def initialize(data)
        super()
        @data = data
        @overrides = {}
      end

      def title
        "method-title"
      end

      def [](key)
        return @overrides[key] if @overrides.key?(key)
        return public_send(key) if self.class.invokable?(key)

        @data[key]
      end
      alias_method :invoke_drop, :[]

      def []=(key, value)
        @overrides[key] = value
      end

      def key?(key)
        !key.nil? && (@overrides.key?(key) || self.class.invokable?(key) || @data.key?(key))
      end

      def each(&block)
        @data.merge(@overrides).each(&block)
      end

      def to_hash
        @data.merge(@overrides)
      end
    end

    class ExplosiveDrop < Liquid::Drop
      attr_reader :reads

      def initialize
        super
        @reads = 0
      end

      def value
        @reads += 1
        raise Liquid::ArgumentError, "guarded lookup"
      end
    end

    class CachedFragmentTag < Liquid::Tag
      def initialize(tag_name, markup, parse_context)
        super
        @name = Liquid::Variable.new(markup.strip, parse_context)
      end

      def render(context)
        name = @name.render(context)
        cache = context.registers[:fragment_templates] ||= {}
        template = cache[name] ||= Liquid::Template.parse(
          context.registers.fetch(:fragment_sources).fetch(name),
          environment: parse_context.environment,
          error_mode: parse_context.error_mode,
          line_numbers: true,
        )
        template.instance_assigns.clear
        context.stack do
          context["fragment"] = { "label" => context["label"] }
          begin
            template.render!(context)
          rescue Liquid::Error => error
            error.template_name = name
            error.markup_context = "nested "
            raise
          end
        end
      end
    end
  end
end
