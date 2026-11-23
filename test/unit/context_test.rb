# frozen_string_literal: true

require "test_helper"
require "bigdecimal"
require_relative "../compatibility/context_audit_cases"

class ContextTest < Minitest::Test
  include CompatibilityContextAuditCases

  def test_evaluate_works_with_normal_values
    context = Liquid::Context.new

    ["abc", 123, false, 1.21, BigDecimal(42)].each do |value|
      assert_equal(value, context.evaluate(value))
    end

    assert_nil(context.evaluate(nil))
  end

  def test_evaluate_works_with_classes_that_have_an_evaluate_method
    class_with_evaluate = Class.new do
      def evaluate(_context)
        42
      end
    end

    assert_equal(42, Liquid::Context.new.evaluate(class_with_evaluate.new))
  end

  def test_evaluate_works_with_variable_lookup
    assert_equal(42, Liquid::Context.new({ "var" => 42 }).evaluate(Liquid::C::Expression.strict_parse("var")))
  end

  def test_native_expression_does_not_use_ruby_variable_lookup
    skip("TracePoint :call not yet supported") if RUBY_ENGINE == "truffleruby"

    context = Liquid::Context.new("var" => 42)
    lookup = Liquid::C::Expression.strict_parse("var")
    context.evaluate(lookup)
    ruby_lookups = []
    trace = TracePoint.new(:call) do |event|
      ruby_lookups << event.method_id if event.defined_class == Liquid::VariableLookup
    end
    result = trace.enable { context.evaluate(lookup) }
    assert_equal(42, result)
    assert_empty(ruby_lookups)
  end

  def test_strict_lookup_rechecks_custom_scope_before_read
    scope = {}
    checks = 0
    scope.define_singleton_method(:key?) { |_key| (checks += 1) == 1 }
    context = Liquid::Context.new
    context.strict_variables = true
    context.stack(scope) do
      assert_raises(Liquid::UndefinedVariable) { context.find_variable("missing") }
    end
    assert_equal(2, checks)
  end

  def test_lazy_lookup_uses_public_proc_arity
    value = proc { |context = nil| context ? "with context" : "without context" }
    value.define_singleton_method(:arity) { 1 }
    assert_equal("with context", Liquid::Context.new("x" => value).find_variable("x"))
  end

  class TestDrop < Liquid::Drop
    def is_filtering # rubocop:disable Naming/PredicateName
      @context.send(:c_filtering?)
    end
  end

  def test_c_filtering_predicate
    context = Liquid::Context.new({ "test" => [TestDrop.new] })
    template = Liquid::Template.parse('{{ test[0].is_filtering }},{{ test | map: "is_filtering" }}')

    assert_equal("false,true", template.render!(context))
    assert_equal(false, context.send(:c_filtering?))
  end

  def test_strict_variables=
    context = Liquid::Context.new
    assert_equal(false, context.strict_variables)
    context.strict_variables = true
    assert_equal(true, context.strict_variables)
  end
end
