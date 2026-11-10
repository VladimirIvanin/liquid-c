# frozen_string_literal: true

module Compatibility
  module Extensions
    class RuntimeExpression
      def evaluate(context)
        context.registers[:expression_calls] = context.registers.fetch(:expression_calls, 0) + 1
        raise Liquid::ArgumentError, "expression failed" if context["expression_failure"]

        context["runtime_value"]
      end
    end

    module ExtraExpressions
      def parse(markup, *args)
        case markup
        when "runtime_literal" then RuntimeExpression.new
        when "filled_literal" then Liquid::Condition::MethodLiteral.new(:filled?, "").freeze
        else super
        end
      end
    end

    class SemanticDrop < Liquid::Drop
      def initialize(value)
        super()
        @value = value
      end

      def filled?
        !@value.nil? && @value != false && @value != ""
      end
    end

    class RegionBlock < Liquid::Block
      def render(context)
        context["region_#{@markup.strip}"] = super
        ""
      end
    end

    class ComponentBlock < Liquid::Block
      def render(context)
        context.stack do
          content = super
          context["component_content"] = "<p>#{content}</p>"
          attributes = [@markup.strip, "content: component_content"]
          context.scopes.first.keys.grep(/\Aregion_/).each do |key|
            attributes << "#{key.delete_prefix("region_")}: #{key}"
          end
          Liquid::Render.parse("render", attributes.join(", "), nil, parse_context).render_tag(context, +"")
        end
      end
    end

    class ParentBodyDrop < Liquid::Drop
      def initialize(template)
        super()
        @template = template
      end

      def super
        @context.stack { @template.root.render_to_output_buffer(@context, +"") }
      end
    end

    class ScopedCollectionDrop < Liquid::Drop
      def initialize(values)
        super()
        @values = values
      end

      def each(&block)
        selection = @context["selection"]
        @values.select { |value| !selection || selection.include?(value) }.each(&block)
      end
    end

    class SelectionBlock < Liquid::Block
      def render(context)
        context.stack("selection" => ["b"]) { super }
      end
    end
  end
end
