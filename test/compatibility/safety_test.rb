# frozen_string_literal: true

require_relative "boot"
require "minitest/autorun"
require_relative "fixtures"

class Liquid514SafetyTest < Minitest::Test
  def test_gc_compaction_keeps_compiled_values_alive
    source = 'é{{ values[0] | append: "!" }}{% capture x %}{{ values[1] }}{% endcapture %}{{ x }}'
    template = Liquid::Template.parse(source, error_mode: :strict)
    5.times do
      GC.start
      if GC.respond_to?(:verify_compaction_references)
        options = RUBY_VERSION >= "3.3" ? { expand_heap: true } : { double_heap: true }
        GC.verify_compaction_references(**options, toward: :empty)
      end
      assert_equal("éA!B", template.render!("values" => ["A", "B"]))
    end
  end

  def test_gc_stress_parse_render
    old_stress = GC.stress
    begin
      GC.stress = true
      template = Liquid::Template.parse('{{ value | append: "!" }}', error_mode: :strict)
      assert_equal("é!", template.render!("value" => "é"))
    ensure
      GC.stress = old_stress
    end
  end

  def test_exception_renderer_raises_without_corrupting_vm
    environment = Liquid::Environment.build { |env| env.register_filter(Compatibility::Filters) }
    context = Liquid::Context.build(environment: environment)
    context.exception_renderer = ->(_error) { raise "renderer failure" }
    template = Liquid::Template.parse("A{{ 1 | explode }}Z", environment: environment, error_mode: :strict)
    3.times do
      error = assert_raises(RuntimeError) { template.render(context) }
      assert_equal("renderer failure", error.message)
    end
    assert_equal("ok", Liquid::Template.parse("{{ value }}").render!("value" => "ok"))
  end

  def test_syntax_error_does_not_poison_next_parse
    5.times do
      assert_raises(Liquid::SyntaxError) { Liquid::Template.parse("{{ x[ }}", error_mode: :strict) }
      assert_equal("ok", Liquid::Template.parse("{{ x }}", error_mode: :strict).render!("x" => "ok"))
    end
  end

  def test_whitespace_only_expression_does_not_overread
    ["", " ", "\t", "\r\n", " " * 4096].each do |expression|
      assert_equal("AZ", Liquid::Template.parse("A{{#{expression}}}Z", error_mode: :strict).render!)
    end
  end

  def test_large_integer_does_not_overflow_native_conversion
    value = 2**100
    assert_equal(value.to_s, Liquid::Template.parse("{{ #{value} }}").render!)
    assert_raises(RangeError) do
      Liquid::Template.parse("{{ x[index] }}").render!("x" => [1], "index" => value)
    end
  end

  def test_inline_comment_inside_liquid_tag_terminates
    template = Liquid::Template.parse("{% liquid\n# ignore this\necho 'ok'\n%}", error_mode: :strict)
    assert_equal("ok", template.render!)
  end

  def test_native_source_size_boundary_and_fallback
    maximum = (1 << 24) - 1
    [maximum - 1, maximum, maximum + 1].each do |size|
      source = "x" * size
      template = Liquid::Template.parse(source, error_mode: :strict)
      assert_equal(size, template.render!.bytesize)
      next unless Compatibility::ENGINE == "c"

      expected = size <= maximum ? "Liquid::C::BlockBody" : "Liquid::BlockBody"
      assert_equal(expected, template.root.body.class.name)
    end
  end

  def test_constant_table_does_not_wrap_at_65536
    require "digest"
    [65_535, 65_536, 65_537].each do |count|
      values = Array.new(count) { |index| (65_536 + index).to_s }
      source = values.map { |value| "{{ #{value} }}|" }.join
      expected = values.join("|") + "|"
      actual = Liquid::Template.parse(source, error_mode: :strict).render!
      assert_equal(Digest::SHA256.hexdigest(expected), Digest::SHA256.hexdigest(actual), "constants=#{count}")
    end
  end

  def test_positional_filter_argument_boundary
    filter = Module.new do
      def argument_count(_input, *arguments)
        arguments.size.to_s
      end
    end
    environment = Liquid::Environment.build { |env| env.register_filter(filter) }
    [254, 255, 256].each do |count|
      source = "{{ 0 | argument_count: #{Array.new(count, "1").join(",")} }}"
      template = Liquid::Template.parse(source, environment: environment, error_mode: :strict)
      assert_equal(count.to_s, template.render!, "arguments=#{count}")
    end
  end

  def test_keyword_filter_argument_boundary
    filter = Module.new do
      def option_count(_input, options = {})
        options.size.to_s
      end
    end
    environment = Liquid::Environment.build { |env| env.register_filter(filter) }
    [255, 256].each do |count|
      options = Array.new(count) { |index| "key#{index}: 1" }.join(",")
      template = Liquid::Template.parse(
        "{{ 0 | option_count: #{options} }}",
        environment: environment,
        error_mode: :strict,
      )
      assert_equal(count.to_s, template.render!, "keywords=#{count}")
    end
  end

  def test_variable_render_hook_is_called
    hook = Module.new do
      def render(context)
        context.registers[:variable_renders] = context.registers.fetch(:variable_renders, 0) + 1
        super
      end
    end
    Liquid::Variable.prepend(hook)
    context = Liquid::Context.build(environments: { "value" => "ok" })
    template = Liquid::Template.parse("{{ value }}", error_mode: :strict)
    assert_equal("ok", template.render!(context))
    assert_equal(1, context.registers[:variable_renders])
  end
end
