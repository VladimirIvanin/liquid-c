# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"

class NativeParserTest < Minitest::Test
  def test_native_payload_matches_ruby_ast
    sources = [
      "",
      " product.title ",
      "foo-bar?",
      "nil",
      "true",
      "empty",
      "-123",
      "1.5",
      "'a b'",
      "obj.first.last.size",
      "obj['first']",
      "obj[other.name][2]",
      "[name].value",
      "(1..3)",
      "(low..high)",
      "value | upcase",
      "value | append: ' x ' | replace: 'a', 'b'",
      "value | custom: arg, key: other.name, second: false",
      "value | custom: key: 1, 2",
      "nil.foo",
      "obj.contains",
      "contains_field",
      "self['foo']",
    ]
    [:lax, :warn, :strict].each do |mode|
      sources.each do |source|
        stats = {}
        native_context = Liquid::ParseContext.new(error_mode: mode, native_parser_stats: stats)
        native_context.liquid_c_nodes_disabled?
        native_context.instance_variable_get(:@expression_cache)["__guard_seed__"] = 0
        ruby_context = Liquid::ParseContext.new(error_mode: mode, disable_liquid_c_nodes: true)
        native = Liquid::Variable.new(source, native_context)
        ruby = Liquid::Variable.new(source, ruby_context)
        assert_equal([snapshot(ruby.name)], [snapshot(native.name)], "#{mode}: #{source}")
        assert_equal(snapshot(ruby.filters), snapshot(native.filters), "#{mode}: #{source}")
        if Liquid::C::NativeParser::NATIVE_GUARDS
          assert_equal(1, stats[:accepted], "#{mode}: #{source}")
        else
          assert_nil(stats[:accepted], "#{mode}: #{source}")
        end
      end
    end
  end

  def test_portable_frontend_amortizes_guards_over_complex_expressions
    source = "value" + (".child" * 256) + " | append: other.name"
    stats = {}
    context = Liquid::ParseContext.new(native_parser_stats: stats)
    context.liquid_c_nodes_disabled?
    native = Liquid::Variable.new(source, context)
    ruby = Liquid::Variable.new(source, Liquid::ParseContext.new(disable_liquid_c_nodes: true))
    assert_equal(snapshot(ruby.name), snapshot(native.name))
    assert_equal(snapshot(ruby.filters), snapshot(native.filters))
    assert_equal(1, stats[:accepted])
  end

  def test_constant_changes_invalidate_guards_before_the_ruby_lexer_has_run
    context = Liquid::ParseContext.new(error_mode: :strict)
    Liquid::Variable.new("value", context)
    previous = Liquid::Lexer::WHITESPACE_OR_NOTHING
    Liquid::Lexer.send(:remove_const, :WHITESPACE_OR_NOTHING)
    Liquid::Lexer.const_set(:WHITESPACE_OR_NOTHING, / */)
    assert_raises(Liquid::SyntaxError) { Liquid::Variable.new("\tvalue", context) }
    # No intervening native parse/reader call: a second change must invalidate
    # the retained IC site even while its entry is already empty.
    Liquid::Lexer.send(:remove_const, :WHITESPACE_OR_NOTHING)
    Liquid::Lexer.const_set(:WHITESPACE_OR_NOTHING, /x*/)
    assert_raises(Liquid::SyntaxError) { Liquid::Variable.new(" value", context) }
  ensure
    Liquid::Lexer.send(:remove_const, :WHITESPACE_OR_NOTHING)
    Liquid::Lexer.const_set(:WHITESPACE_OR_NOTHING, previous)
  end

  def test_tracepoint_observes_the_original_parser
    calls = 0
    trace = TracePoint.new(:call) do |event|
      calls += 1 if event.defined_class == Liquid::Parser && event.method_id == :expression
    end
    stats = {}
    trace.enable do
      assert_equal("ok", Liquid::Template.parse("{{ value }}", native_parser_stats: stats).render!("value" => "ok"))
    end
    assert_operator(calls, :>, 0)
    refute(stats.key?(:accepted))
  ensure
    trace&.disable
  end

  def test_non_string_cache_keys_use_the_original_cache_protocol
    stats = {}
    cache = { Object.new => 42 }
    context = Liquid::ParseContext.new(native_parser_stats: stats, expression_cache: cache)
    context.liquid_c_nodes_disabled?
    variable = Liquid::Variable.new("value", context)
    assert_equal("value", variable.name.name)
    refute(stats.key?(:accepted))
    assert(cache.keys.any? { |key| key.instance_of?(Object) })
  end

  def test_parser_hook_installed_after_loading_is_called
    original = Liquid::ParseContext.instance_method(:new_parser)
    calls = []
    Liquid::ParseContext.define_method(:new_parser) do |markup|
      calls << markup
      original.bind_call(self, markup)
    end
    assert_equal("ok", Liquid::Template.parse("{{ value }}").render!("value" => "ok"))
    assert_equal([" value "], calls)
  ensure
    Liquid::ParseContext.define_method(:new_parser, original) if original
  end

  def test_singleton_context_hook_is_called
    context = Liquid::ParseContext.new
    calls = []
    context.define_singleton_method(:new_parser) do |markup|
      calls << markup
      super(markup)
    end
    Liquid::Variable.new("value", context)
    assert_equal(["value"], calls)
  end

  def test_cache_and_filters_have_the_same_sharing_contract
    context = Liquid::ParseContext.new
    first = Liquid::Variable.new("obj.title | upcase", context)
    second = Liquid::Variable.new("obj.title | upcase", context)
    assert_same(first.name, second.name)
    assert_predicate(first.name, :frozen?)
    refute_same(first.filters, second.filters)
    refute_same(first.filters.first, second.filters.first)
    refute_same(first.filters.first[1], second.filters.first[1])
    assert_equal(["obj.title"], context.instance_variable_get(:@expression_cache).keys)
  end

  def test_unsupported_parse_does_not_publish_temporary_cache_entries
    cache = {}
    assert_nil(Liquid::C.native_parse_variable("value | append:", cache))
    assert_empty(cache)
  end

  def test_strict2_uses_the_original_parser
    stats = {}
    Liquid::Variable.new("self['value']", Liquid::ParseContext.new(error_mode: :strict2, native_parser_stats: stats))
    assert_empty(stats)
  end

  def test_mutating_the_lexer_table_uses_the_ruby_lexer
    table = Liquid::Lexer::SPECIAL_TABLE
    previous = table[".".ord]
    table[".".ord] = Liquid::Lexer::PIPE
    stats = {}
    variable = Liquid::Variable.new("obj.title", Liquid::ParseContext.new(native_parser_stats: stats))
    assert_equal("obj", variable.name.name)
    assert_equal(["title"], variable.filters.map(&:first))
    refute(stats.key?(:accepted))
  ensure
    table[".".ord] = previous if table
  end

  def test_replacing_the_literal_table_is_respected
    original = Liquid::Expression::LITERALS
    Liquid::Expression.send(:remove_const, :LITERALS)
    Liquid::Expression.const_set(:LITERALS, original.merge("special_literal" => 42).freeze)
    variable = Liquid::Variable.new("special_literal", Liquid::ParseContext.new)
    assert_equal(42, variable.name)
  ensure
    Liquid::Expression.send(:remove_const, :LITERALS)
    Liquid::Expression.const_set(:LITERALS, original)
  end

  def test_singleton_scanner_hooks_are_called
    context = Liquid::ParseContext.new
    scanner = context.instance_variable_get(:@string_scanner)
    calls = 0
    scanner.define_singleton_method(:peek_byte) do
      calls += 1
      super()
    end
    Liquid::Variable.new("value", context)
    assert_operator(calls, :>, 0)
  end

  def test_integer_conversion_hooks_are_not_executed_speculatively
    original = Integer.instance_method(:to_i)
    calls = []
    Integer.define_method(:to_i) do
      calls << self
      original.bind_call(self)
    end
    variable = Liquid::Variable.new("(1..3)", Liquid::ParseContext.new)
    assert_equal(1..3, variable.name)
    assert_equal([1, 3], calls)
    calls.clear
    assert_raises(Liquid::SyntaxError) { Liquid::Variable.new("((1..2)..3)", Liquid::ParseContext.new) }
    assert_equal([1, 2], calls)
  ensure
    Integer.define_method(:to_i, original) if original
  end

  def test_private_parser_helpers_are_not_bypassed
    Liquid::Parser.send(:private, :look)
    assert_raises(NoMethodError) { Liquid::Template.parse("{{ product.title }}") }
  ensure
    Liquid::Parser.send(:public, :look)
  end

  def test_identity_cache_keeps_distinct_expression_objects
    cache = {}.compare_by_identity
    context = Liquid::ParseContext.new(error_mode: :strict)
    context.instance_variable_set(:@expression_cache, cache)
    context.liquid_c_nodes_disabled?
    variable = Liquid::Variable.new("foo | default: foo", context)
    assert_equal(2, cache.size)
    refute_same(variable.name, variable.filters.first[1].first)
  end

  def test_parser_alias_installed_before_loading_is_respected
    assert_parser_child(<<~RUBY)
      require "liquid"
      Liquid::Parser.alias_method(:expression, :consume)
      require "liquid/c"
      begin
        Liquid::Template.parse("{{ obj#{".child" * 256} }}", error_mode: :strict)
        abort "aliased parser was bypassed"
      rescue Liquid::SyntaxError
      end
    RUBY
  end

  def test_guard_setup_does_not_trigger_unrelated_autoload
    assert_parser_child(<<~RUBY)
      require "liquid"
      Liquid::Expression.autoload(:UnusedNativeGuardProbe, "must-not-be-loaded-by-guard")
      require "liquid/c"
      Liquid::Variable.new("foo", Liquid::ParseContext.new)
      abort "autoload was consumed" unless Liquid::Expression.autoload?(:UnusedNativeGuardProbe)
    RUBY
  end

  def test_constant_guard_checks_autoload_without_calling_owner_override
    owner = Module.new
    owner.autoload(:NativeGuardProbe, "must-not-be-loaded-by-guard")
    owner.define_singleton_method(:autoload?) { |*| raise "autoload? override was called" }

    refute(Liquid::C.native_constant_matches?(owner, :NativeGuardProbe, Object, nil))
    autoload_path = Module.instance_method(:autoload?).bind_call(owner, :NativeGuardProbe, false)
    assert_equal("must-not-be-loaded-by-guard", autoload_path)

    owner.send(:remove_const, :NativeGuardProbe)
    owner.const_set(:NativeGuardProbe, Object)
    assert(Liquid::C.native_constant_matches?(owner, :NativeGuardProbe, Object, nil))
  end

  def test_primitive_change_during_native_allocation_discards_result
    skip("requires instrumented native build") unless Liquid::C.respond_to?(:native_parser_test_callback=)

    assert_parser_child(<<~RUBY)
      require "liquid/c"
      Liquid::C.native_parser_test_callback = -> { raise "injected" }
      begin
        Liquid::C.native_parse_variable("foo.bar", {})
        abort "injected exception was lost"
      rescue RuntimeError => error
        abort error.message unless error.message == "injected"
      end
      GC.start
      abort "parser did not recover" unless Liquid::C.native_parse_variable("foo.bar", {}).is_a?(Array)
      fired = false
      original = Array.instance_method(:<<)
      Liquid::C.native_parser_test_callback = -> do
        fired = true
        Array.define_method(:<<) { |value| original.bind_call(self, value) }
        GC.start
      end
      result = Liquid::C.native_parse_variable("foo.bar", {})
      abort "injection did not run" unless fired
      abort "stale primitive assumptions accepted" unless result.nil?
    RUBY
  end

  def test_enabled_getter_hook_is_not_called_speculatively
    original = Liquid::C.method(:enabled)
    saved_option = ENV["LIQUID_C_NATIVE_PARSER"]
    calls = 0
    Liquid::C.define_singleton_method(:enabled) do
      calls += 1
      original.call
    end
    source = "{{ obj#{".child" * 256} }}"
    ENV["LIQUID_C_NATIVE_PARSER"] = "false"
    Liquid::Template.parse(source, error_mode: :strict)
    expected = calls
    calls = 0
    ENV.delete("LIQUID_C_NATIVE_PARSER")
    Liquid::Template.parse(source, error_mode: :strict)
    assert_equal(expected, calls)
  ensure
    Liquid::C.singleton_class.define_method(:enabled, original) if original
    ENV["LIQUID_C_NATIVE_PARSER"] = saved_option
  end

  def test_private_singleton_context_method_uses_original_parser
    context = Liquid::ParseContext.new(error_mode: :strict)
    context.liquid_c_nodes_disabled?
    context.new_parser("foo.bar")
    variable = Liquid::Variable.new("foo.bar", context)
    context.singleton_class.send(:private, :safe_parse_expression)
    refute(Liquid::C::NativeParser.send(:compatible?, context, variable))
    assert_raises(NoMethodError) { Liquid::Variable.new("foo#{".child" * 256}", context) }
  end

  def test_private_lookup_evaluation_uses_the_ruby_range_parser
    Liquid::VariableLookup.send(:private, :evaluate)
    context = Liquid::ParseContext.new
    context.liquid_c_nodes_disabled?
    assert_raises(Liquid::SyntaxError) { Liquid::Variable.new("(first..last)", context) }
  ensure
    Liquid::VariableLookup.send(:public, :evaluate)
  end

  def test_numeric_evaluate_hooks_keep_dynamic_range_objects
    Integer.define_method(:evaluate) { |_context| self }
    context = Liquid::ParseContext.new
    context.liquid_c_nodes_disabled?
    variable = Liquid::Variable.new("(1..3)", context)
    assert_instance_of(Liquid::RangeLookup, variable.name)
    assert_equal(1, variable.name.start_obj)
    assert_equal(3, variable.name.end_obj)
  ensure
    Integer.send(:remove_method, :evaluate)
  end

  def test_string_range_conversion_hooks_keep_the_ruby_order
    original = String.instance_method(:to_i)
    calls = []
    String.define_method(:to_i) do |*args|
      calls << self
      original.bind_call(self, *args)
    end
    variable = Liquid::Variable.new("('1'..'3')", Liquid::ParseContext.new)
    assert_equal(1..3, variable.name)
    assert_equal(["1", "3"], calls)
  ensure
    String.define_method(:to_i, original) if original
  end

  def test_variable_subclass_parser_helpers_are_called
    calls = []
    subclass = Class.new(Liquid::Variable) do
      define_method(:parse_filterargs) do |parser|
        calls << :arguments
        super(parser)
      end
    end
    variable = subclass.new("value | append: 'x'", Liquid::ParseContext.new)
    assert_equal([:arguments], calls)
    assert_equal("vx", variable.render(Liquid::Context.new("value" => "v")))
  end

  def test_singleton_variable_parser_helpers_are_called
    variable = Liquid::Variable.allocate
    calls = []
    variable.define_singleton_method(:parse_filterargs) do |parser|
      calls << :arguments
      super(parser)
    end
    variable.send(:initialize, "value | append: 'x'", Liquid::ParseContext.new)
    assert_equal([:arguments], calls)
  end

  def test_lookup_freeze_hooks_are_called_once
    # Restoring a C method with define_method clears MRI's BASIC flag. Keep
    # that deliberate mutation out of the remaining fast-path tests.
    code = <<~RUBY
      $LOAD_PATH.unshift(ENV["LIQUID_C_EXTENSION_DIR"]) if ENV["LIQUID_C_EXTENSION_DIR"]
      require "liquid/c"
      original = Liquid::VariableLookup.instance_method(:freeze)
      calls = 0
      Liquid::VariableLookup.define_method(:freeze) do
        calls += 1
        original.bind_call(self)
      end
      Liquid::Variable.new("value", Liquid::ParseContext.new)
      abort "unexpected freeze callback count: \#{calls}" unless calls == 1
    RUBY
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", code)
    assert_predicate(status, :success?, stdout + stderr)
  end

  def test_context_hook_is_not_called_by_eligibility_checks
    context = Liquid::ParseContext.new
    calls = 0
    context.define_singleton_method(:liquid_c_nodes_disabled?) do
      calls += 1
      false
    end
    Liquid::Variable.new("value", context)
    assert_equal(0, calls)
  end

  def test_strict_parse_return_value_and_non_utf8_markup_match_ruby
    context = Liquid::ParseContext.new
    variable = Liquid::Variable.new("value", context)
    assert_nil(variable.strict_parse("value"))
    markup = "value".encode(Encoding::US_ASCII)
    variable = Liquid::Variable.new(markup, Liquid::ParseContext.new)
    ruby = Liquid::Variable.new(markup, Liquid::ParseContext.new(disable_liquid_c_nodes: true))
    assert_equal(snapshot(ruby.name), snapshot(variable.name))
  end

  private

  def assert_parser_child(code)
    prefix = '$LOAD_PATH.unshift(ENV["LIQUID_C_EXTENSION_DIR"]) if ENV["LIQUID_C_EXTENSION_DIR"]; '
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", prefix + code)
    assert_predicate(status, :success?, stdout + stderr)
  end

  def snapshot(value)
    case value
    when Liquid::VariableLookup
      [
        :lookup,
        snapshot(value.name),
        snapshot(value.lookups),
        value.instance_variable_get(:@command_flags),
        value.frozen?,
      ]
    when Liquid::RangeLookup
      [:range_lookup, snapshot(value.start_obj), snapshot(value.end_obj), value.frozen?]
    when Array
      value.map { |item| snapshot(item) }
    when Hash
      value.transform_values { |item| snapshot(item) }
    when String
      [:string, value, value.encoding.name, value.frozen?]
    else
      value
    end
  end
end
