# frozen_string_literal: true

module CompatibilityContextAuditCases
  def test_disabling_native_engine_inside_filter_preserves_strict_lookups
    enabled = Liquid::C.enabled if defined?(Liquid::C)
    filters = Module.new do
      def disable_and_require_variables(value)
        Liquid::C.enabled = false if defined?(Liquid::C)
        @context.strict_variables = true
        value
      end
    end
    environment = Liquid::Environment.build { |env| env.register_filter(filters) }
    template = Liquid::Template.parse(
      "{{ value | disable_and_require_variables | append: missing }}",
      environment: environment,
    )
    context = Liquid::Context.build(environments: { "value" => "v" }, environment: environment)
    assert_raises(Liquid::UndefinedVariable) { template.render!(context) }
  ensure
    Liquid::C.enabled = enabled if defined?(Liquid::C)
  end

  def test_reused_context_observes_global_filter_changes
    context = Liquid::Context.new("value" => "hello")
    template = Liquid::Template.parse("{{ value }}")
    assert_equal("hello", template.render!(context))

    context.global_filter = ->(value) { value.upcase }
    assert_equal("HELLO", template.render!(context))
    context.global_filter = nil
    assert_equal("hello", template.render!(context))
  end

  def test_reused_context_observes_strict_filter_changes
    context = Liquid::Context.new("value" => "hello")
    template = Liquid::Template.parse("{{ value | audit_missing_filter }}")
    assert_equal("hello", template.render!(context))

    context.strict_filters = true
    assert_raises(Liquid::UndefinedFilter) { template.render!(context) }
    context.strict_filters = false
    assert_equal("hello", template.render!(context))
  end

  def test_reused_context_observes_added_filters
    context = Liquid::Context.new("value" => "hello")
    template = Liquid::Template.parse("{{ value | audit_added_filter }}")
    assert_equal("hello", template.render!(context))

    context.add_filters(Module.new do
      def audit_added_filter(value)
        value.upcase
      end
    end)
    assert_equal("HELLO", template.render!(context))
  end

  def test_context_settings_refresh_after_reenabling_native_engine
    context = Liquid::Context.new("value" => "hello")
    template = Liquid::Template.parse("{{ value | audit_toggle_filter }}")
    assert_equal("hello", template.render!(context))
    was_enabled = Liquid::C.enabled if defined?(Liquid::C)
    begin
      Liquid::C.enabled = false if defined?(Liquid::C)
      context.global_filter = ->(value) { "[#{value}]" }
      context.strict_filters = true
      context.strict_variables = true
      context.add_filters(Module.new do
        def audit_toggle_filter(value)
          value.upcase
        end
      end)
      Liquid::C.enabled = was_enabled if defined?(Liquid::C)
      assert_equal("[HELLO]", template.render!(context))
      assert_raises(Liquid::UndefinedFilter) do
        Liquid::Template.parse("{{ value | audit_missing_filter }}").render!(context)
      end
      assert_raises(Liquid::UndefinedVariable) do
        Liquid::Template.parse("{{ missing }}").render!(context)
      end
    ensure
      Liquid::C.enabled = was_enabled if defined?(Liquid::C)
    end
  end

  def test_disabling_native_engine_inside_filter_preserves_live_context_settings
    [false, true].each do |evaluate_while_disabled|
      was_enabled = Liquid::C.enabled if defined?(Liquid::C)
      filter = Module.new do
        define_method(:audit_disable_native) do |value|
          Liquid::C.enabled = false if defined?(Liquid::C)
          if evaluate_while_disabled && was_enabled && @context.respond_to?(:c_evaluate)
            @context.c_evaluate(Liquid::C::Expression.strict_parse("value"))
          end
          @context.global_filter = ->(result) { result.upcase }
          value
        end
      end
      environment = Liquid::Environment.build { |env| env.register_filter(filter) }
      context = Liquid::Context.build(environment: environment, environments: { "value" => "hello" })
      template = Liquid::Template.parse("{{ value | audit_disable_native }}", environment: environment)
      begin
        assert_equal("HELLO", template.render!(context))
      ensure
        Liquid::C.enabled = was_enabled if defined?(Liquid::C)
      end
    end
  end

  def test_context_settings_changed_inside_filter_apply_immediately
    filter = Module.new do
      def audit_change_context(value)
        @context.global_filter = ->(result) { "[#{result}]" }
        @context.strict_filters = true
        value
      end
    end
    environment = Liquid::Environment.build { |env| env.register_filter(filter) }
    context = Liquid::Context.build(environment: environment, environments: { "value" => "hello" })
    template = Liquid::Template.parse("{{ value | audit_change_context }}", environment: environment)
    assert_equal("[hello]", template.render!(context))
    template = Liquid::Template.parse(
      "{{ value | audit_change_context | audit_missing_filter }}",
      environment: environment,
    )
    assert_raises(Liquid::UndefinedFilter) { template.render!(context) }
  end

  def test_filters_added_inside_filter_apply_to_the_next_filter
    added_filter = Module.new do
      def audit_dynamic_filter(value)
        value.upcase
      end
    end
    installer = Module.new do
      define_method(:audit_install_filter) do |value|
        @context.add_filters(added_filter)
        value
      end
    end
    environment = Liquid::Environment.build { |env| env.register_filter(installer) }
    context = Liquid::Context.build(environment: environment, environments: { "value" => "hello" })
    template = Liquid::Template.parse(
      "{{ value | audit_install_filter | audit_dynamic_filter }}",
      environment: environment,
    )
    assert_equal("HELLO", template.render!(context))
  end

  def test_reentrant_variable_render_preserves_live_outer_arguments
    observer = Module.new do
      def render(context)
        context.registers[:audit_variable] = self
        super
      end
    end
    Liquid::Variable.prepend(observer)
    context = Liquid::Context.new("value" => "x")
    nested = false
    context.environments.first["trigger"] = proc do |render_context|
      if nested
        "!"
      else
        begin
          nested = true
          render_context.registers[:audit_variable].render(render_context)
        ensure
          nested = false
        end
      end
    end
    assert_equal("xx!", Liquid::Template.parse("{{ value | append: trigger }}").render!(context))
  ensure
    observer&.remove_method(:render)
  end

  def test_reentrant_variable_render_recovers_after_nested_exception
    observer = Module.new do
      def render(context)
        context.registers[:audit_variable] = self
        super
      end
    end
    Liquid::Variable.prepend(observer)
    context = Liquid::Context.new("value" => "x")
    nested = false
    recovered = 0
    context.environments.first["trigger"] = proc do |render_context|
      if nested
        raise Liquid::ArgumentError, "nested failure"
      else
        begin
          nested = true
          render_context.registers[:audit_variable].render(render_context)
        rescue Liquid::ArgumentError
          recovered += 1
          "!"
        ensure
          nested = false
        end
      end
    end
    template = Liquid::Template.parse("{{ value | append: trigger }}")
    2.times { assert_equal("x!", template.render!(context)) }
    assert_equal(1, recovered)
    assert_empty(context.errors)
  ensure
    observer&.remove_method(:render)
  end

  def test_nil_environment_values_continue_to_later_environments
    context = Liquid::Context.new([{ "value" => nil }, { "value" => "found" }])
    assert_equal("found", context["value"])
    context.strict_variables = true
    assert_nil(context["value"])
  end

  def test_proc_returning_nil_continues_to_later_environments_and_is_memoized
    calls = 0
    environment = {
      "value" => -> {
        calls += 1
        nil
      },
    }
    context = Liquid::Context.new([environment, { "value" => "found" }])
    2.times { assert_equal("found", context["value"]) }
    assert_equal(1, calls)
    assert_nil(environment["value"])
  end

  def test_strict_missing_first_environment_raises_before_later_environment
    context = Liquid::Context.new([{}, { "value" => "found" }])
    context.strict_variables = true
    assert_raises(Liquid::UndefinedVariable) { context["value"] }
    assert_equal("found", context.find_variable("value", raise_on_not_found: false))
  end

  def test_optional_and_splat_procs_receive_context_in_all_lookups
    ["value", "nested.value"].each do |expression|
      [
        ->(context = nil) { context.is_a?(Liquid::Context) ? "context" : "missing" },
        proc { |*arguments| arguments.first.is_a?(Liquid::Context) ? "context" : "missing" },
      ].each do |callable|
        values = expression == "value" ? { "value" => callable } : { "nested" => { "value" => callable } }
        context = Liquid::Context.new(values)
        assert_equal("context", Liquid::Template.parse("{{ #{expression} }}").render!(context))
        assert_equal("context", context[expression])
        assert_equal("context", context[expression])
      end
    end
  end

  def test_hash_subclass_scope_materializes_proc_once
    scope = Class.new(Hash).new
    calls = 0
    scope["value"] = -> { calls += 1 }
    context = Liquid::Context.new
    context.scopes[0] = scope
    2.times { assert_equal(1, context["value"]) }
    assert_equal(1, calls)
  end

  def test_builtin_subclasses_with_evaluate_methods_are_evaluated
    [String, Array, Hash].each do |base|
      expression = Class.new(base) do
        def evaluate(context)
          context["value"]
        end
      end.new
      assert_equal("evaluated", Liquid::Context.new("value" => "evaluated").evaluate(expression))
    end
  end

  def test_hash_subclass_and_singleton_lookup_overrides_are_respected
    subclass = Class.new(Hash) do
      def [](key)
        "override #{super}"
      end
    end.new
    singleton = { "value" => "stored" }
    def singleton.[](key)
      "override #{super}"
    end
    subclass["value"] = "stored"

    [subclass, singleton].each do |values|
      assert_equal("override stored", Liquid::Context.new(values)["value"])
      context = Liquid::Context.new
      context.scopes[0] = values
      assert_equal("override stored", context["value"])
    end
  end
end
