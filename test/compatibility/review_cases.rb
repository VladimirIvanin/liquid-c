# frozen_string_literal: true

module CompatibilityReviewCases
  def test_review_strict_mode_changes_inside_lazy_values
    [true, false].each do |strict|
      context = Liquid::Context.new([
        {
          "x" => ->(ctx) {
            ctx.strict_variables = strict
            nil
          },
        },
        { "x" => "fallback" },
      ])
      context.strict_variables = !strict
      if strict
        assert_nil(context.find_variable("x"))
      else
        assert_equal("fallback", context.find_variable("x"))
      end
    end
  end

  def test_review_empty_environments_in_strict_context
    context = Liquid::Context.build(environments: [], static_environments: [])
    context.strict_variables = true
    assert_nil(context.find_variable("missing"))
  end

  def test_review_context_copies_have_independent_native_settings
    context = Liquid::Context.new("x" => "ok")
    assert_equal("ok", context["x"])
    [:dup, :clone].each do |method|
      copy = context.public_send(method)
      copy.strict_variables = true
      assert_raises(Liquid::UndefinedVariable) { copy["missing"] }
      assert_nil(context["missing"])
      copy.global_filter = ->(value) { value.upcase }
      template = Liquid::Template.parse("{{ x }}")
      assert_equal("OK", template.render!(copy))
      assert_equal("ok", template.render!(context))
    end
  end

  def test_review_nil_key_predicate_does_not_call_brackets
    object = Class.new do
      def to_liquid
        self
      end

      define_method(:key?) { |_key| nil }

      def [](_key)
        raise "unexpected brackets"
      end
    end.new
    assert_equal("", Liquid::Template.parse("{{ obj.missing }}").render!("obj" => object))
  end

  def test_review_strict_numeric_hash_lookup_does_not_invoke_default
    hash = Hash.new { raise "unexpected default" }
    assert_raises(Liquid::UndefinedVariable) do
      Liquid::Template.parse("{{ obj[0] }}").render!({ "obj" => hash }, strict_variables: true)
    end
    assert_equal("", Liquid::Template.parse("{{ obj[0] }}").render!({ "obj" => [] }, strict_variables: true))
  end

  def test_review_strict_accessor_and_lookup_state_follow_ruby_boundaries
    hash = Hash.new("default")
    context = Liquid::Context.new("obj" => hash)
    def context.strict_variables
      true
    end
    assert_equal("default", Liquid::Template.parse("{{ obj[0] }}").render!(context))
    assert_raises(Liquid::UndefinedVariable) do
      Liquid::Template.parse("{{ obj.missing }}").render!(context)
    end
  end

  def test_review_missing_lookup_skips_later_keys_but_present_nil_does_not
    [{}, { "missing" => nil }].each do |object|
      calls = 0
      key = -> {
        calls += 1
        "key"
      }
      template = Liquid::Template.parse("{{ obj.missing[side] }}")
      assert_equal("", template.render!("obj" => object, "side" => key))
      assert_equal(object.key?("missing") ? 1 : 0, calls)
    end
    calls = 0
    template = Liquid::Template.parse("{{ obj.missing[other.missing[side]] | default: 'ok' }}")
    assert_equal("ok", template.render!("obj" => {}, "other" => {}, "side" => -> { calls += 1 }))
    assert_equal(0, calls)
  end

  def test_review_symbol_values_are_converted_to_strings
    assert_equal("h|o", Liquid::Template.parse("{{ x.first }}|{{ x.last }}").render!("x" => :hello))
  end

  def test_review_nested_conversion_sets_context_after_to_liquid
    value_class = Class.new do
      attr_writer :context

      def to_liquid
        @context ? "after" : "before"
      end
    end
    assert_equal("before", Liquid::Template.parse("{{ obj.x }}").render!("obj" => { "x" => value_class.new }))
    assert_equal("after", Liquid::Template.parse("{{ x }}").render!("x" => value_class.new))
  end

  def test_review_top_conversion_respects_ruby_inequality
    target = Object.new
    target.define_singleton_method(:context=) { |_context| raise "unexpected context setter" }
    source = Object.new
    source.define_singleton_method(:to_liquid) { target }
    source.define_singleton_method(:!=) { |_other| false }
    assert_same(target, Liquid::Context.new("x" => source).find_variable("x"))
  end

  def test_review_string_lookup_key_can_define_to_liquid_value
    key = +"alias"
    key.define_singleton_method(:to_liquid_value) { "actual" }
    template = Liquid::Template.parse("{{ obj[key] }}")
    assert_equal("ok", template.render!("obj" => { "actual" => "ok" }, "key" => key))
  end

  def test_review_string_first_fallback_preserves_false_and_context_semantics
    value = Class.new(String) do
      def [](_index)
        false
      end
    end.new("x")
    assert_equal("", Liquid::Template.parse("{{ x.first }}").render!("x" => value))

    contexts = []
    character = Object.new
    character.define_singleton_method(:context=) { |context| contexts << context }
    character.define_singleton_method(:to_s) { "ok" }
    value = Class.new(String) do
      define_method(:[]) { |_index| character }
    end.new("x")
    context = Liquid::Context.new("x" => value)
    assert_equal("ok", Liquid::Template.parse("{{ x.first }}").render!(context))
    assert_equal([context], contexts)
  end

  def test_review_range_strings_use_decimal_conversion
    { "010" => "10..10", "0x10" => "0..0", "0b10" => "0..0", "12tail" => "12..12" }.each do |value, expected|
      assert_equal(expected, Liquid::Template.parse("{{ (x..x) }}").render!("x" => value))
    end
    value = Class.new(String) do
      def to_i
        7
      end
    end.new("010")
    assert_equal("7..7", Liquid::Template.parse("{{ (x..x) }}").render!("x" => value))
  end

  def test_review_raw_closing_tag_inside_variable
    assert_equal("{{ }}", Liquid::Template.parse("{% raw %}{{ {% endraw %}}}").render!)
    assert_equal("{{Z", Liquid::Template.parse("{% raw %}{{{% endraw -%} Z").render!)
    assert_raises(Liquid::SyntaxError) { Liquid::Template.parse("{% raw %}" + "{{" * 10_000) }
  end

  def test_review_nested_filter_argument_error
    filter = Module.new do
      def review_nested(value)
        Liquid::Template.parse("{{ 1 | plus: 1 }}").render!(@context)
        raise ArgumentError, "outer failure"
      end
    end
    error = assert_raises(Liquid::ArgumentError) do
      Liquid::Template.parse("{{ x | review_nested }}").render!({ "x" => 1 }, filters: [filter])
    end
    assert_equal("Liquid error: outer failure", error.message)
  end

  def test_review_variable_error_text_counts_toward_length_limit
    template = Liquid::Template.parse("{{ x | slice }}")
    template.resource_limits.render_length_limit = 10
    assert_equal("Liquid error: Memory limits exceeded", template.render({}))
    assert_instance_of(Liquid::MemoryError, template.errors.last)
  end

  def test_review_interrupt_from_variable_stops_block
    [Liquid::BreakInterrupt, Liquid::ContinueInterrupt].each do |interrupt|
      filter = Module.new do
        define_method(:review_interrupt) do |value|
          @context.push_interrupt(interrupt.new)
          value
        end
      end
      template = Liquid::Template.parse("{% for i in (1..2) %}a{{ 'X' | review_interrupt }}tail{% endfor %}end")
      expected = interrupt == Liquid::BreakInterrupt ? "aXend" : "aXaXend"
      assert_equal(expected, template.render!({}, filters: [filter]))
    end
  end

  def test_review_write_score_uses_bytesize_protocol
    output = Class.new(String) do
      def bytesize
        100
      end
    end.new("x")
    limits = Liquid::ResourceLimits.new(render_length_limit: 10)
    assert_raises(Liquid::MemoryError) { limits.increment_write_score(output) }
    limits = Liquid::ResourceLimits.new({})
    assert_nil(limits.increment_write_score(Object.new))
    length = 2**100
    object = Object.new
    object.define_singleton_method(:bytesize) { length }
    limits.with_capture { limits.increment_write_score(object) }
    assert_equal(length, limits.assign_score)
  end

  def test_review_resource_limit_overrides_are_called
    limits = Liquid::ResourceLimits.new({})
    writes = 0
    limits.define_singleton_method(:increment_write_score) do |output|
      writes += 1
      super(output)
    end
    context = Liquid::Context.build(environments: { "x" => "ok" }, resource_limits: limits)
    assert_equal("ok", Liquid::Template.parse("{{ x }}").render!(context))
    assert_equal(1, writes)
  end

  def test_review_settings_do_not_initialize_strainer
    context = Liquid::Context.new
    def context.strainer
      raise "unexpected strainer"
    end
    context.strict_variables = true
    context.strict_filters = true
    context.global_filter = ->(value) { value }
    assert_equal(true, context.strict_variables)
  end
end
