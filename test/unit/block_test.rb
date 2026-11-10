# frozen_string_literal: true

require "test_helper"

class BlockTest < Minitest::Test
  def test_multiline_tag_prefix_updates_error_location
    ["{% #\nfoo\nbar %}", "{%\n#\nfoo\nbar %}"].each_with_index do |source, index|
      error = assert_raises(Liquid::SyntaxError) do
        Liquid::Template.parse(source, error_mode: :strict2, line_numbers: true)
      end
      assert_equal(index + 2, error.line_number)
    end
  end

  def test_no_allocation_of_trimmed_strings
    template = Liquid::Template.parse("{{ a -}}     {{- b }}")
    assert_equal(2, template.root.nodelist.size)

    template = Liquid::Template.parse("{{ a -}} foo {{- b }}")
    assert_equal(3, template.root.nodelist.size)
  end

  def test_empty_ascii_output_preserves_compatible_encoding
    output = String.new(encoding: Encoding::ASCII)
    template = Liquid::Template.parse("ascii text")
    assert_same(output, template.render!({}, output: output))
    assert_equal("ascii text", output)
    assert_equal(Encoding::US_ASCII, output.encoding)
  end

  def test_write_unicode_characters
    output = String.new(encoding: Encoding::UTF_8)
    template = Liquid::Template.parse("ü{{ unicode_char }}")
    assert_equal("üñ", template.render!({ "unicode_char" => "ñ" }, output: output))
  end

  def test_op_write_raw_w
    source = "a" * 2**8
    template = Liquid::Template.parse(source)
    assert_equal(source, template.render!)
  end

  def test_raise_for_non_c_parse_context
    parse_context = Liquid::ParseContext.new
    assert_raises(RuntimeError) do
      Liquid::C::BlockBody.new(parse_context)
    end
  end

  # Test for bug: https://github.com/Shopify/liquid-c/pull/120
  def test_bug_120_instrument
    calls = []
    Liquid::Usage.stub(:increment, ->(name) { calls << name }) do
      Liquid::Template.parse("{{ -.1 }}", error_mode: :lax)
    end
    assert_equal(["liquid_c_negative_float_without_integer"], calls)

    calls = []
    Liquid::Usage.stub(:increment, ->(name) { calls << name }) do
      Liquid::Template.parse("{{ .1 }}", error_mode: :lax)
    end
    assert_equal([], calls)
  end

  def test_mutating_exposed_variable_tree_changes_rendering
    template = Liquid::Template.parse('{{ value | append: "!" }}')
    assert_equal("A!", template.render!("value" => "A"))
    variable = template.root.body.nodelist.first
    variable.filters.first[1][0] = "?"
    2.times { assert_equal("A?", template.render!("value" => "A")) }
  end

  def test_exposed_tree_keeps_native_variable_hooks_and_exceptions_balanced
    template = Liquid::Template.parse("{{ value | plus: 1 }}")
    template.root.body.nodelist
    assert_equal("3", template.render!("value" => 2))
    assert_equal("4", template.render!("value" => 3))
  end

  def test_disassemble_uses_constants_for_each_block
    template = Liquid::Template.parse("{% if x %}{{ inner }}{% endif %}{{ outer }}")
    root = template.root.body
    conditional = root.nodelist.first
    disassembly = root.disassemble
    assert_includes(disassembly, 'find_static_var("outer")')
    assert_includes(disassembly, "write_node(#{conditional.inspect})")
    inner = conditional.blocks.first.attachment
    assert_includes(inner.disassemble, 'find_static_var("inner")')
  end

  def test_variable_compiler_must_leave_one_value
    original = Liquid::Variable.instance_method(:compile_evaluate)
    [0, 2].each do |count|
      Liquid::Variable.define_method(:compile_evaluate) do |code|
        count.times { code.add_evaluate_expression(1) }
      end
      error = assert_raises(RuntimeError) { Liquid::Template.parse("{{ value }}") }
      assert_includes(error.message, "exactly 1 new element")
    end
  ensure
    Liquid::Variable.define_method(:compile_evaluate, original)
  end

  def test_disassemble_raw_w
    source = "a" * 2**8
    template = Liquid::Template.parse(source)
    block_body = template.root.body
    assert_equal(<<~ASM, block_body.disassemble)
      0x0000: write_raw_w("#{source}")
      0x0104: leave
    ASM
  end

  def test_disassemble
    source = <<~LIQUID
      raw
      {{- var | default: "none", allow_false: true -}}
      {%- increment counter -%}
    LIQUID
    template = Liquid::Template.parse(source, line_numbers: true)
    block_body = template.root.body
    increment_node = block_body.nodelist[2]
    assert_instance_of(Liquid::Increment, increment_node)
    assert_equal(<<~ASM, block_body.disassemble)
      0x0000: write_raw("raw")
      0x0005: render_variable_rescue(line_number: 2)
      0x000d: find_static_var("var")
      0x0012: push_const("none")
      0x0017: push_const("allow_false")
      0x001c: push_true
      0x001d: hash_new(1)
      0x001f: builtin_filter(name: :default, num_args: 3)
      0x0022: pop_write
      0x0023: write_node(#{increment_node.inspect})
      0x0028: leave
    ASM
  end

  def test_exception_renderer_exception
    original_error = Liquid::Error.new("original")
    handler_error = RuntimeError.new("exception handler error")
    context = Liquid::Context.new("raise_error" => ->(_ctx) { raise(original_error) })
    context.exception_renderer = lambda do |exc|
      if exc == original_error
        raise(handler_error)
      end

      exc
    end
    template = Liquid::Template.parse("{% assign x = raise_error %}")
    exc = assert_raises(RuntimeError) do
      template.render(context)
    end
    assert_equal(handler_error, exc)
  end

  StubFileSystem = Struct.new(:partials) do
    def read_template_file(template_path)
      partials.fetch(template_path)
    end
  end

  def test_include_partial_with_syntax_error
    old_file_system = Liquid::Template.file_system
    begin
      Liquid::Template.file_system = StubFileSystem.new({
        "invalid" => "{% foo %}",
        "valid" => '{% include "nested" %}',
        "nested" => "valid",
      })

      template = Liquid::Template.parse("{% include 'invalid' %},{% include 'valid' %}")
      assert_equal("Liquid syntax error: Unknown tag 'foo',valid", template.render)
    ensure
      Liquid::Template.file_system = old_file_system
    end
  end

  def test_assign_filter_argument_exception
    source = "{% assign v = 'IN' | truncate: 123, liquid_error %}{{ v | default: 'err swallowed' }}"
    template = Liquid::Template.parse(source)
    output = template.render({ "liquid_error" => -> { raise Liquid::Error, "var lookup error" } })
    assert_equal("err swallowed", output)
  end
end
