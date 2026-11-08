# frozen_string_literal: true

require "base64"
require "bigdecimal"
require_relative "fixtures"

module Compatibility
  module Observation
    class << self
      def normalize(value, active = {}.compare_by_identity)
        if value.is_a?(Array) || value.is_a?(Hash)
          return { "recursive" => true } if active.key?(value)

          active[value] = true
          begin
            return value.map { |entry| normalize(entry, active) } if value.is_a?(Array)

            # JSON object keys would collapse 1, "1", and :"1", and lose
            # binary key encodings. Encode keys as values instead.
            return { "hash" => value.map { |key, entry| [normalize(key, active), normalize(entry, active)] } }
          ensure
            active.delete(value)
          end
        end
        case value
        when String
          { "bytes" => Base64.strict_encode64(value.b), "encoding" => value.encoding.name }
        when Symbol
          { "symbol" => value.to_s }
        when NilClass, TrueClass, FalseClass, Numeric
          value
        else
          normalize(value.to_s)
        end
      end

      def error(error)
        {
          class: error.class.name,
          message: normalize(error.message),
          line: error.respond_to?(:line_number) ? error.line_number : nil,
        }
      end

      def environment
        Liquid::Environment.build(error_mode: MODE) do |env|
          env.register_filter(Filters)
          env.register_tag("marker", MarkerTag)
          env.register_tag("buffer", BufferBlock)
        end.dup
      end

      def call(scenario)
        env = environment
        return { value: normalize(api(scenario.fetch(:operation), env)) } if scenario[:operation]

        assigns = Marshal.load(Marshal.dump(scenario.fetch(:assigns, {})))
        assigns["x"] = -> { "proc" } if scenario[:id] == "proc_lookup"
        assigns["x"] = ["a", [1, nil, "b"]] if scenario[:id] == "nested_arrays"
        template = Liquid::Template.parse(
          scenario.fetch(:source),
          environment: env,
          error_mode: MODE,
          line_numbers: true,
          **scenario.fetch(:options, {}),
        )
        context = Liquid::Context.build(environment: env, environments: assigns)
        output = template.render(context)
        {
          output: normalize(output),
          errors: context.errors.map { |entry| error(entry) },
          warnings: template.warnings.map { |entry| error(entry) },
          state: normalize(context.scopes.last),
          calls: context.registers[:calls],
        }
      rescue StandardError, SystemStackError => exception
        { exception: error(exception) }
      end

      def api(operation, env)
        parse_context = Liquid::ParseContext.new(environment: env, error_mode: MODE)
        context = Liquid::Context.build(environment: env, environments: { "x" => "ok", "title" => "T" })
        case operation
        when "safe"
          context.evaluate(parse_context.parse_expression("x", safe: true))
        when "unsafe"
          context.evaluate(parse_context.parse_expression("x"))
        when "cache", "cache_disabled"
          cache = operation == "cache" ? {} : false
          parse_context = Liquid::ParseContext.new(environment: env, error_mode: :strict, expression_cache: cache)
          first = parse_context.parse_expression("x")
          second = parse_context.parse_expression("x")
          keys = operation == "cache" ? cache.keys : false
          [first.equal?(second), first.frozen?, keys]
        when "limits"
          limits = Liquid::ResourceLimits.new({})
          [limits.reached?, limits.render_length_limit, limits.render_score_limit, limits.assign_score_limit]
        when "cumulative_render", "cumulative_assign", "render_reset", "assign_reset"
          kind = operation.include?("assign") ? "assign" : "render"
          limits = Liquid::ResourceLimits.new("cumulative_#{kind}_score_limit".to_sym => 2)
          limits.public_send("increment_#{kind}_score", 2)
          limits.reset
          if operation.end_with?("reset")
            [limits.reached?, limits.public_send("cumulative_#{kind}_score")]
          else
            limits.public_send("increment_#{kind}_score", 1)
            "limit not enforced"
          end
        when "context_drop"
          drop = ContextDrop.new
          context["drop"] = drop
          output = template("{{ drop.title }}", env).render!(context)
          [output, drop.events]
        when "drop_index", "drop_key"
          context["values"] = operation == "drop_index" ? ["a", "b"] : { "key" => "ok" }
          context["index"] = ValueDrop.new(operation == "drop_index" ? 1 : "key")
          template("{{ values[index] }}", env).render!(context)
        when "drop_false", "drop_comparison"
          context["drop"] = ValueDrop.new(operation == "drop_false" ? false : 1)
          source = if operation == "drop_false"
            "{% if drop %}yes{% else %}no{% endif %}"
          else
            "{% if drop == 1 %}yes{% else %}no{% endif %}"
          end
          template(source, env).render!(context)
        when "static_environment"
          context = Liquid::Context.build(
            environment: env,
            static_environments: { "x" => "static" },
            environments: { "x" => "dynamic" },
          )
          [context["x"], template("{{ x }}", env).render!(context)]
        when "filter_reload"
          template('{{ "x" | later }}', env).render!
          filter = Module.new { def later(input) = "new:#{input}" }
          env.register_filter(filter)
          template('{{ "x" | later }}', env).render!
        when "registers"
          context.registers[:value] = "local"
          inner = context.new_isolated_subcontext
          [context.registers[:value], inner.registers[:value]]
        when "include", "render_isolation"
          file_system = FileSystem.new("item" => '{{ title }}{% assign title = "Changed" %}')
          env.file_system = file_system
          source = if operation == "include"
            '{% include "item" %}|{{ title }}'
          else
            '{% render "item", title: "Local" %}|{{ title }}'
          end
          context = Liquid::Context.build(environment: env, environments: { "title" => "Parent" })
          parsed = template(source, env)
          [parsed.render!(context), parsed.render!(context), file_system.reads]
        when "binary_buffer"
          output = String.new(capacity: 10)
          template("ü{{ x }}", env).render!({ "x" => "ñ" }, output: output)
        when "profile"
          require "liquid/profiler"
          parsed = Liquid::Template.parse("{{ x }}", environment: env, error_mode: MODE, profile: true)
          [parsed.render!("x" => "T"), parsed.root.body.class.name, parsed.profiler.total_render_time >= 0]
        when "visit"
          parsed = template("A{{ x }}{% assign y = x %}", env)
          [
            parsed.root.body.nodelist.map { |node| node.is_a?(String) ? "text" : node.class.name },
            Liquid::ParseTreeVisitor.for(parsed.root)
              .add_callback_for(Liquid::VariableLookup) { |node, _context| node.name }.visit.flatten.compact,
          ]
        when "marshal"
          limits = Liquid::ResourceLimits.new({})
          Marshal.load(Marshal.dump(limits)).render_score
        else
          raise ArgumentError, "Unknown operation #{operation}"
        end
      end

      def template(source, environment)
        Liquid::Template.parse(source, environment: environment, error_mode: MODE, line_numbers: true)
      end
    end
  end
end
