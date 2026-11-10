# frozen_string_literal: true

require "test_helper"

class ReviewTest < Minitest::Test
  def test_expression_identifiers_with_contains
    values = { "contains_field" => "ok", "contains?" => "yes", "obj" => { "contains" => "nested" } }
    context = Liquid::Context.new(values)
    { "contains_field" => "ok", "contains?" => "yes", "obj.contains" => "nested" }.each do |source, expected|
      assert_equal(expected, context.evaluate(Liquid::C::Expression.strict_parse(source)))
    end
  end

  def test_expression_invalid_utf8_and_negative_decimal
    assert_raises(Liquid::SyntaxError) { Liquid::C::Expression.strict_parse((+"\xC2").force_encoding("UTF-8")) }
    assert_raises(Liquid::SyntaxError) { Liquid::C::Expression.strict_parse("-.5") }
    expression = Liquid::C::Expression.lax_parse("-.5")
    assert_nil(Liquid::Context.new.evaluate(expression))
  end

  def test_numeric_parse_does_not_mutate_source_when_warning_raises
    [false, true].each do |frozen|
      source = "(" + "9" * 400 + ".0..x)"
      before = source.dup
      source.freeze if frozen
      Warning.stub(:warn, ->(*) { raise "warning failure" }) do
        verbose = $VERBOSE
        begin
          $VERBOSE = true
          assert_raises(RuntimeError) { Liquid::C::Expression.strict_parse(source) }
        ensure
          $VERBOSE = verbose
        end
      end
      assert_equal(before, source)
    end
    assert_equal(123, Liquid::C::Expression.strict_parse("123"))
  end

  def test_numeric_parse_keeps_snapshot_when_warning_mutates_input
    source = "9" * 400 + ".0"
    callback = ->(*) {
      source.replace("x")
      GC.start
    }
    Warning.stub(:warn, callback) do
      verbose = $VERBOSE
      begin
        $VERBOSE = true
        assert_equal(1, Liquid::C::Expression.strict_parse(source).infinite?)
      ensure
        $VERBOSE = verbose
      end
    end
    assert_equal("x", source)
  end

  def test_expression_reuse_preserves_source_instructions
    expression = Liquid::C::Expression.strict_parse("obj.x.y")
    original = expression.disassemble
    compiler = Liquid::Variable.instance_method(:compile_evaluate)
    Liquid::Variable.define_method(:compile_evaluate) { |code| code.add_evaluate_expression(expression) }
    3.times do
      template = Liquid::Template.parse("{{ value }}|{{ value }}")
      assert_equal("ok|ok", template.render!("obj" => { "x" => { "y" => "ok" } }))
      assert_equal(original, expression.disassemble)
      assert_equal("ok", expression.evaluate(Liquid::Context.new("obj" => { "x" => { "y" => "ok" } })))
    end
  ensure
    Liquid::Variable.define_method(:compile_evaluate, compiler) if compiler
  end

  def test_singleton_expression_evaluate_is_dispatched
    expression = Liquid::C::Expression.strict_parse("x")
    def expression.evaluate(_context)
      "hook"
    end
    assert_equal("hook", Liquid::Context.new("x" => "wrong").evaluate(expression))
  end

  def test_singleton_expression_evaluate_is_used_by_compiler
    expression = Liquid::C::Expression.strict_parse("x")
    def expression.evaluate(_context)
      "hook"
    end
    compiler = Liquid::Variable.instance_method(:compile_evaluate)
    Liquid::Variable.define_method(:compile_evaluate) { |code| code.add_evaluate_expression(expression) }
    assert_equal("hook", Liquid::Template.parse("{{ x }}").render!("x" => "wrong"))
  ensure
    Liquid::Variable.define_method(:compile_evaluate, compiler) if compiler
  end

  def test_native_expression_lookup_short_circuit_preserves_present_nil
    [{}, { "x" => nil }].each do |object|
      calls = 0
      key = -> {
        calls += 1
        "y"
      }
      context = Liquid::Context.new("obj" => object, "key" => key)
      expression = Liquid::C::Expression.strict_parse("obj.x[key]")
      assert_nil(expression.evaluate(context))
      assert_equal(object.key?("x") ? 1 : 0, calls)
    end
    context = Liquid::Context.new("obj" => { "x" => { "y" => "ok" } }, "nested" => {}, "fallback" => "y")
    expression = Liquid::C::Expression.strict_parse("obj.x[nested.missing[fallback]]")
    assert_nil(expression.evaluate(context))
  end

  def test_hash_key_callback_can_reallocate_vm_stack
    filters = Module.new do
      def review_many(value, *)
        value
      end

      def review_hash(_value, options)
        options.values.first
      end
    end
    context = Liquid::Context.new("value" => "ok")
    context.add_filters(filters)
    nested = Liquid::Template.parse("{{ value | review_many: " + Array.new(64, "'argument'").join(", ") + " }}")
    key = Object.new
    key.define_singleton_method(:hash) do
      nested.render!(context)
      1
    end
    compiler = Liquid::Variable.instance_method(:compile_evaluate)
    Liquid::Variable.define_method(:compile_evaluate) do |code|
      code.add_evaluate_expression("input")
      code.add_evaluate_expression(key)
      code.add_evaluate_expression("value")
      code.add_hash_new(1)
      code.add_filter("review_hash", 1)
    end
    template = Liquid::Template.parse("{{ value }}")
    assert_equal("value", template.render!(context))
  ensure
    Liquid::Variable.define_method(:compile_evaluate, compiler) if compiler
  end

  def test_compiler_rejects_nonstring_filter_name
    compiler = Liquid::Variable.instance_method(:compile_evaluate)
    Liquid::Variable.define_method(:compile_evaluate) do |code|
      code.add_evaluate_expression("input")
      code.add_filter(:invalid, 0)
    end
    assert_raises(TypeError) { Liquid::Template.parse("{{ x }}") }
  ensure
    Liquid::Variable.define_method(:compile_evaluate, compiler) if compiler
  end

  def test_disassemble_requires_compiled_body
    parse_context = Liquid::ParseContext.new
    parse_context.start_liquid_c_parsing
    body = Liquid::C::BlockBody.new(parse_context)
    assert_raises(RuntimeError) { body.disassemble }
  ensure
    parse_context&.cleanup_liquid_c_parsing
  end

  def test_tokenizer_matches_ruby_on_incomplete_variables
    ["{{\nx", "{{ {% broken", "{{ {% endraw %}}}", "{{ {", "{{}"].each do |source|
      ruby_tokens = Liquid::ParseContext.new(disable_liquid_c_nodes: true).new_tokenizer(source, start_line_number: 1)
      native_tokens = Liquid::C::Tokenizer.new(source, 1, false)
      expected = []
      while (token = ruby_tokens.shift)
        expected << [token, ruby_tokens.line_number]
      end
      actual = []
      while (token = native_tokens.shift)
        actual << [token, native_tokens.line_number]
      end
      assert_equal(expected, actual, source)
    end
  end

  def test_add_filters_does_not_construct_strainer
    context = Liquid::Context.new("x" => "ok")
    context["x"]
    def context.strainer
      raise "unexpected strainer"
    end
    assert_nil(context.add_filters(Module.new))
  end

  def test_context_refresh_retries_after_callback_exception
    context = Liquid::Context.new("value" => "hello")
    template = Liquid::Template.parse("{{ value }}")
    assert_equal("hello", template.render!(context))
    context.ruby_global_filter = ->(value) { value.upcase }
    Liquid::C::VM.invalidate_contexts
    def context.strainer
      unless @review_failed
        @review_failed = true
        raise "temporary strainer failure"
      end
      super
    end
    assert_raises(RuntimeError) { template.render!(context) }
    assert_equal("HELLO", template.render!(context))
  end

  def test_context_refresh_preserves_filter_changes_inside_callback
    context = Liquid::Context.new("value" => "hello")
    template = Liquid::Template.parse("{{ value | review_added }}")
    assert_equal("hello", template.render!(context))
    filter = Module.new do
      def review_added(value)
        value.upcase
      end
    end
    changed = false
    context.define_singleton_method(:global_filter) do
      unless changed
        changed = true
        add_filters(filter)
      end
      super()
    end
    Liquid::C::VM.invalidate_contexts
    assert_equal("HELLO", template.render!(context))
  end

  def test_context_refresh_retries_if_generation_changes_during_callback
    context = Liquid::Context.new("value" => "hello")
    template = Liquid::Template.parse("{{ value }}")
    template.render!(context)
    Liquid::C::VM.invalidate_contexts
    def context.global_filter
      unless @review_changed
        @review_changed = true
        self.ruby_global_filter = ->(value) { value.upcase }
        Liquid::C::VM.invalidate_contexts
        return
      end
      super
    end
    template.render!(context)
    assert_equal("HELLO", template.render!(context))
  end
end
