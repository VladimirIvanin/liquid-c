# frozen_string_literal: true

require "test_helper"

class NativeTagsTest < Minitest::Test
  def test_conditions_keep_the_ruby_tree_and_method_literals
    [
      "x",
      "x == 1",
      "x contains 'a'",
      "x == empty or y != blank and z",
      "(1..3) contains x",
      "obj[key].first >= 1",
      "product#{".child" * 40}.value == 1",
      "true and false or true",
    ].each do |expression|
      source = "{% if #{expression} %}yes{% else %}no{% endif %}"
      stats = {}
      native = Liquid::Template.parse(source, error_mode: :strict, native_parser_stats: stats)
      ruby = Liquid::Template.parse(source, error_mode: :strict, disable_liquid_c_nodes: true)
      left = native.root.nodelist.first.blocks.first
      right = ruby.root.nodelist.first.blocks.first
      assert_equal(condition_snapshot(right), condition_snapshot(left), expression)
      if Liquid::C::NativeParser::NATIVE_GUARDS && expression.include?(".child")
        assert_equal(1, stats[:accepted_condition], expression)
      else
        assert_nil(stats[:accepted_condition], expression)
      end
      [{}, { "x" => 1, "y" => [], "z" => true }, { "x" => "a", "obj" => { "a" => [2] }, "key" => "a" }].each do |values|
        assert_equal(ruby.render(values), native.render(values), expression)
      end
    end
  end

  def test_for_header_fields_and_continuation_cache_match_ruby
    [
      "i in values",
      "i in (1..4) reversed limit: 2",
      "i in values offset: continue limit: count",
      "i in obj[ key ] , offset: start, limit: 2",
      "i in values limit: 2 limit: 1",
      "i in 'a b'",
      "i in product#{".child" * 40}.values",
    ].each do |header|
      source = "{% for #{header} %}{{ i }}{% else %}empty{% endfor %}"
      stats = {}
      native = Liquid::Template.parse(source, error_mode: :strict, native_parser_stats: stats)
      ruby = Liquid::Template.parse(source, error_mode: :strict, disable_liquid_c_nodes: true)
      left = native.root.nodelist.first
      right = ruby.root.nodelist.first
      fields = [:@variable_name, :@collection_name, :@name, :@reversed, :@from, :@limit]
      assert_equal(
        fields.map { |name| expression_snapshot(right.instance_variable_get(name)) },
        fields.map { |name| expression_snapshot(left.instance_variable_get(name)) },
        header,
      )
      if Liquid::C::NativeParser::NATIVE_GUARDS && header.include?(".child")
        assert_equal(1, stats[:accepted_for], header)
      else
        assert_nil(stats[:accepted_for], header)
      end
      values = { "values" => [1, 2, 3], "count" => 2, "start" => 1, "key" => "a", "obj" => { "a" => [4, 5] } }
      assert_equal(ruby.render(values), native.render(values), header)
    end
    cache = {}
    Liquid::Template.parse(
      "{% for i in values offset: continue %}{{ i }}{% endfor %}",
      error_mode: :strict,
      expression_cache: cache,
    )
    refute_includes(cache.keys, "continue")
  end

  def test_condition_constructor_hooks_disable_the_native_frontend
    original = Liquid::Condition.instance_method(:initialize)
    calls = 0
    Liquid::Condition.define_method(:initialize) do |*args|
      calls += 1
      original.bind_call(self, *args)
    end
    stats = {}
    assert_equal("yes", Liquid::Template.parse(
      "{% if true %}yes{% endif %}",
      error_mode: :strict,
      native_parser_stats: stats,
    ).render!)
    assert_equal(1, calls)
    refute(stats.key?(:accepted_condition))
  ensure
    Liquid::Condition.define_method(:initialize, original) if original
  end

  def test_for_attribute_hooks_are_called
    original = Liquid::For.instance_method(:set_attribute)
    calls = []
    Liquid::For.define_method(:set_attribute) do |key, expression, **options|
      calls << key
      original.bind_call(self, key, expression, **options)
    end
    assert_equal("1", Liquid::Template.parse(
      "{% for i in (1..4) limit: 1 %}{{ i }}{% endfor %}",
      error_mode: :strict,
    ).render!)
    assert_equal(["limit"], calls)
  ensure
    Liquid::For.define_method(:set_attribute, original) if original
    Liquid::For.send(:private, :set_attribute) if original
  end

  def test_case_deep_lookup_preserves_its_tree_and_cache
    expression = "product#{".child" * 40}.value"
    value = { "value" => 2 }
    40.times { value = { "child" => value } }
    source = "{% case #{expression} %}{% when 2 %}yes{% else %}no{% endcase %}" * 2
    stats = {}
    native = Liquid::Template.parse(source, error_mode: :strict, native_parser_stats: stats)
    ruby = Liquid::Template.parse(source, error_mode: :strict, disable_liquid_c_nodes: true)
    assert_equal("yesyes", native.render!("product" => value))
    assert_equal(
      expression_snapshot(ruby.root.nodelist.first.left),
      expression_snapshot(native.root.nodelist.first.left),
    )
    if Liquid::C::NativeParser::NATIVE_GUARDS
      assert_equal(1, stats[:accepted_case])
    else
      assert_nil(stats[:accepted_case])
    end
    assert_same(native.root.nodelist.first.left, native.root.nodelist.last.left)
  end

  private

  def condition_snapshot(condition)
    [
      expression_snapshot(condition.left),
      expression_snapshot(condition.operator),
      expression_snapshot(condition.right),
      condition.instance_variable_get(:@child_relation),
      condition.child_condition && condition_snapshot(condition.child_condition),
    ]
  end

  def expression_snapshot(value)
    case value
    when Liquid::VariableLookup
      [
        :lookup,
        expression_snapshot(value.name),
        value.lookups.map { |entry| expression_snapshot(entry) },
        value.instance_variable_get(:@command_flags),
        value.frozen?,
      ]
    when Liquid::RangeLookup
      [:range, expression_snapshot(value.start_obj), expression_snapshot(value.end_obj), value.frozen?]
    when Liquid::Condition::MethodLiteral
      [:method, value.method_name, value.to_s]
    when String
      [value, value.encoding.name, value.frozen?]
    else
      value
    end
  end
end
