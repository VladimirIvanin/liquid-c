# frozen_string_literal: true

require_relative "boot"
require "minitest/autorun"
require "minitest/mock"
require "bigdecimal"
require_relative "fixtures"

class Liquid514RegressionTest < Minitest::Test
  TEMPLATE_CASES = {
    string_first: ["{{ x.first }}", { "x" => "éЖ" }, "é"],
    string_last: ["{{ x.last }}", { "x" => "éЖ" }, "Ж"],
    empty_string_first: ["[{{ x.first }}]", { "x" => "" }, "[]"],
    negative_decimal: ["{{ -0.5 | times: 2 }}", {}, "-1.0"],
    nested_array: ["{{ x }}", { "x" => ["a", [1, nil, "b"]] }, "a1b"],
    decimal_output: ["{{ x }}", { "x" => BigDecimal("12.3") }, "12.3"],
    unicode_lookup: ['{{ x["заголовок"] }}', { "x" => { "заголовок" => "Каталог" } }, "Каталог"],
    nil_output: ["[{{ x }}]", { "x" => nil }, "[]"],
    false_output: ["{{ x }}", { "x" => false }, "false"],
    false_default: ['{{ false | default: "fallback" }}', {}, "fallback"],
    false_default_allowed: ['{{ false | default: "fallback", allow_false: true }}', {}, "false"],
    empty_array_truthiness: ["{% if x %}yes{% endif %}", { "x" => [] }, "yes"],
    zero_truthiness: ["{% if x %}yes{% endif %}", { "x" => 0 }, "yes"],
    blank_comparison: ["{% if x == blank %}yes{% endif %}", { "x" => " " }, "yes"],
    empty_comparison: ["{% if x == empty %}yes{% endif %}", { "x" => [] }, "yes"],
    nil_contains: ["{% if x contains nil %}yes{% endif %}", { "x" => [nil] }, ""],
    string_limit_offset: ['{% for i in (1..5) limit: "2" offset: "1" %}{{ i }}{% endfor %}', {}, "23"],
    continue_offset: [
      "{% for i in (1..5) limit: 2 %}{{ i }}{% endfor %}|" \
        "{% for i in (1..5) offset: continue limit: 2 %}{{ i }}{% endfor %}",
      {},
      "12|34",
    ],
    reverse_slice: ["{% for i in (1..5) reversed offset: 1 limit: 2 %}{{ i }}{% endfor %}", {}, "32"],
    range_break: ["{% for i in (1..5) %}{{ i }}{% break %}{% endfor %}", {}, "1"],
    range_continue: ["{% for i in (1..3) %}{% if i == 2 %}{% continue %}{% endif %}{{ i }}{% endfor %}", {}, "13"],
    parentloop: [
      "{% for i in (1..2) %}{% for j in (1..2) %}" \
        "{{ forloop.parentloop.index }}{{ forloop.index }};{% endfor %}{% endfor %}",
      {},
      "11;12;21;22;",
    ],
    empty_loop_else: ["{% for i in x %}bad{% else %}empty{% endfor %}", { "x" => [] }, "empty"],
    case_fallthrough: ["{% case x %}{% when 1 %}a{% when 1 %}b{% else %}c{% endcase %}", { "x" => 1 }, "ab"],
    case_multiple_values: ["{% case x %}{% when 1, 2 %}yes{% else %}no{% endcase %}", { "x" => 2 }, "yes"],
    capture: ['A{% capture x %}{{ "é" | upcase }}{% endcapture %}{{ x }}Z', {}, "AÉZ"],
    counters_separate_from_assign: ["{% assign x = 9 %}{% increment x %}{{ x }}{% decrement x %}", {}, "090"],
    liquid_tag: ["{% liquid\nassign x = 1\necho x | plus: 2\n%}", {}, "3"],
    inline_comment: ["A{% # ignored %}B", {}, "AB"],
    doc: ["A{% doc %}{{ unknown }}{% bad_tag %}{% enddoc %}B", {}, "AB"],
    comment_unknown_tag: ["A{% comment %}{% unknown %}{{ x }}{% endcomment %}B", {}, "AB"],
    nested_comment: ["A{% comment %}x{% comment %}y{% endcomment %}z{% endcomment %}B", {}, "AB"],
    raw: ["A{% raw %}{{ x }}{% endraw %}B", {}, "A{{ x }}B"],
    raw_trim: [" A {%- raw -%} {{ x }} {% endraw -%} B ", {}, " A {{ x }} B "],
    whitespace_only_trim: ["{% if true %}left{% endif %}\t {{- '' -}} right", {}, "leftright"],
    crlf_filter: ["{{ x | newline_to_br }}", { "x" => "a\r\nb" }, "a<br />\nb"],
    literal_dotted_key: [
      '{{ x | map: "a.b" | join: "," }}',
      { "x" => [{ "a.b" => "literal", "a" => { "b" => "nested" } }] },
      "literal",
    ],
    find_empty: ['[{{ x | find: "a", 1 }}]', { "x" => [] }, "[]"],
    find_index_empty: ['[{{ x | find_index: "a", 1 }}]', { "x" => [] }, "[]"],
    has_empty: ['{{ x | has: "a", 1 }}', { "x" => [] }, "false"],
    reject_filter: ['{{ x | reject: "a", 1 | map: "a" | join: "," }}', { "x" => [{ "a" => 1 }, { "a" => 2 }] }, "2"],
    positional_and_keyword_filter: ['{{ "a" | probe: "b", label: "c" }}', {}, "abc"],
    nul_literal: ["a\0{{ x }}", { "x" => "b" }, "a\0b"],
  }.freeze

  TEMPLATE_CASES.each do |name, (source, assigns, expected)|
    define_method("test_#{name}") do
      assert_equal(expected, render(source, assigns))
    end
  end

  def setup
    @environment = Liquid::Environment.build(error_mode: Compatibility::MODE) do |environment|
      environment.register_filter(Compatibility::Filters)
      environment.register_tag("marker", Compatibility::MarkerTag)
      environment.register_tag("buffer", Compatibility::BufferBlock)
    end.dup
  end

  def test_safe_expression_keyword
    parse_context = Liquid::ParseContext.new(error_mode: :strict2)
    expression = parse_context.parse_expression("title", safe: true)
    assert_equal("ok", Liquid::Context.new("title" => "ok").evaluate(expression))
  end

  def test_strict2_unsafe_expression_is_rejected
    parse_context = Liquid::ParseContext.new(error_mode: :strict2)
    assert_raises(Liquid::InternalError) { parse_context.parse_expression("title") }
  end

  def test_expression_cache_is_populated
    cache = {}
    parse_context = Liquid::ParseContext.new(error_mode: :strict, expression_cache: cache)
    first = parse_context.parse_expression("title")
    second = parse_context.parse_expression("title")
    assert_same(first, second)
    assert(cache.key?("title"))
  end

  def test_expression_cache_disabled
    parse_context = Liquid::ParseContext.new(error_mode: :strict, expression_cache: false)
    refute_same(parse_context.parse_expression("title"), parse_context.parse_expression("title"))
  end

  def test_expression_is_frozen
    expression = Liquid::ParseContext.new(error_mode: :strict).parse_expression("title")
    assert_predicate(expression, :frozen?)
  end

  def test_strict2_rejects_bare_brackets
    assert_raises(Liquid::SyntaxError) { parse("{{ [key] }}", error_mode: :strict2) }
  end

  def test_strict2_self_lookup
    assert_equal("ok", render('{{ self["title"] }}', { "title" => "ok" }, error_mode: :strict2))
  end

  def test_explicit_self_shadows_implicit_self
    assert_equal(
      "inner",
      render("{{ self.title }}", { "self" => { "title" => "inner" }, "title" => "outer" }, error_mode: :strict2),
    )
  end

  def test_rigid_alias_enforces_strict2
    assert_raises(Liquid::SyntaxError) { parse("{{ [key] }}", error_mode: :rigid) }
  end

  def test_unset_limits_are_nil
    limits = Liquid::ResourceLimits.new({})
    assert_nil(limits.render_length_limit)
    assert_nil(limits.render_score_limit)
    assert_nil(limits.assign_score_limit)
  end

  def test_fresh_limits_have_not_been_reached
    refute_predicate(Liquid::ResourceLimits.new({}), :reached?)
  end

  def test_reset_clears_reached_flag
    limits = Liquid::ResourceLimits.new(render_score_limit: 1)
    assert_raises(Liquid::MemoryError) { limits.increment_render_score(2) }
    limits.reset
    refute_predicate(limits, :reached?)
  end

  ["render", "assign"].each do |kind|
    define_method("test_cumulative_#{kind}_limit") do
      limits = Liquid::ResourceLimits.new("cumulative_#{kind}_score_limit".to_sym => 2)
      limits.public_send("increment_#{kind}_score", 2)
      limits.reset
      assert_raises(Liquid::MemoryError) { limits.public_send("increment_#{kind}_score", 1) }
    end

    define_method("test_cumulative_#{kind}_counter_survives_reset") do
      limits = Liquid::ResourceLimits.new({})
      limits.public_send("increment_#{kind}_score", 2)
      limits.reset
      assert_equal(0, limits.public_send("#{kind}_score"))
      assert_equal(2, limits.public_send("cumulative_#{kind}_score"))
    end
  end

  def test_filter_argument_error_is_translated
    error = assert_raises(Liquid::ArgumentError) { render("{{ 1 | ruby_explode }}") }
    assert_includes(error.message, "ruby probe failure")
  end

  def test_strict_filters
    template = parse('{{ "x" | nonexistent_filter }}')
    assert_raises(Liquid::UndefinedFilter) { template.render!({}, strict_filters: true) }
  end

  def test_strict_variables_missing
    assert_raises(Liquid::UndefinedVariable) { parse("{{ missing }}").render!({}, strict_variables: true) }
  end

  def test_strict_variables_defined_nil
    assert_equal("", parse("{{ x }}").render!({ "x" => nil }, strict_variables: true))
  end

  def test_custom_tag_runs_once
    context = Liquid::Context.build(environment: @environment, environments: { "title" => "T" })
    assert_equal("A[T]Z", parse("A{% marker %}Z").render!(context))
    assert_equal(1, context.registers[:calls])
  end

  def test_custom_block_uses_existing_buffer_once
    output = +"prefix:"
    result = parse("A{% buffer %}{{ title }}{% endbuffer %}Z").render!({ "title" => "T" }, output: output)
    assert_same(output, result)
    assert_equal("prefix:A<T>Z", result)
  end

  def test_binary_output_with_unicode
    output = String.new(capacity: 10)
    assert_equal("üñ", parse("ü{{ x }}").render!({ "x" => "ñ" }, output: output))
    assert_equal(Encoding::UTF_8, output.encoding)
  end

  def test_nested_include_reexecutes_cached_partial
    file_system = Compatibility::FileSystem.new(
      "outer" => '{{ title }}:{{ label }}{% include "inner" %}',
      "inner" => '[{{ label }}]{% assign title = "Changed" %}',
    )
    @environment.file_system = file_system
    template = parse('A{% include name, label: "Local" %}|{{ label }}|{{ title }}Z')
    context = Liquid::Context.build(environment: @environment, environments: { "name" => "outer", "title" => "Parent" })
    assert_equal("AParent:Local[Local]||ChangedZ", template.render!(context))
    context["title"] = "Second"
    assert_equal("ASecond:Local[Local]||ChangedZ", template.render!(context))
    assert_equal(["outer", "inner"], file_system.reads)
  end

  def test_render_isolates_assignments
    @environment.file_system = Compatibility::FileSystem.new("item" => '{{ title }}{% assign title = "Changed" %}')
    assert_equal("Local|Parent", render('{% render "item", title: "Local" %}|{{ title }}', { "title" => "Parent" }))
  end

  def test_environment_filter_isolation
    other = Liquid::Environment.build
    first = render('{{ "a" | probe }}')
    second = Liquid::Template.parse('{{ "a" | probe }}', environment: other).render!
    assert_equal("a!", first)
    assert_equal("a", second)
  end

  def test_register_filter_after_strainer_was_created
    assert_equal("x", render('{{ "x" | later }}'))
    filter = Module.new { def later(input) = "new:#{input}" }
    @environment.register_filter(filter)
    assert_equal("new:x", render('{{ "x" | later }}'))
  end

  def test_drop_receives_context_before_to_liquid
    drop = Compatibility::ContextDrop.new
    assert_equal("T", render("{{ drop.title }}", { "drop" => drop, "title" => "T" }))
    assert_equal(["context", "liquid_with_context"], drop.events.first(2))
  end

  def test_drop_as_array_index
    assert_equal(
      "b",
      render("{{ values[index] }}", { "values" => ["a", "b"], "index" => Compatibility::ValueDrop.new(1) }),
    )
  end

  def test_drop_as_hash_key
    assert_equal(
      "ok",
      render("{{ values[index] }}", { "values" => { "key" => "ok" }, "index" => Compatibility::ValueDrop.new("key") }),
    )
  end

  def test_registers_changes_are_local
    registers = Liquid::Registers.new(value: "static")
    registers[:value] = "local"
    assert_equal("local", registers[:value])
    registers.delete(:value)
    assert_equal("static", registers[:value])
  end

  def test_reuse_template_after_filter_exception
    template = parse("{{ x | explode }}")
    2.times { assert_raises(Liquid::ArgumentError) { template.render!("x" => 1) } }
    assert_equal("ok", render("{{ x }}", { "x" => "ok" }))
  end

  def test_render_error_has_line_number_and_no_duplicate_output
    context = Liquid::Context.build(environment: @environment)
    context.exception_renderer = ->(error) { "ERR:#{error.line_number}" }
    assert_equal("A\nERR:2Z", parse("A\n{{ 1 | explode }}Z", line_numbers: true).render(context))
    assert_equal(1, context.errors.size)
    assert_equal(2, context.errors.first.line_number)
  end

  def test_expression_state_after_exception
    context = Liquid::Context.build(environment: @environment, rethrow_errors: true)
    context["drop"] = Compatibility::FailingDrop.new
    expression = Liquid::Expression.parse("drop.title")
    assert_raises(Liquid::ArgumentError) { context.evaluate(expression) }
    assert_equal(3, context.evaluate(Liquid::Expression.parse("3")))
  end

  def test_large_range_does_not_materialize
    range = (1..1_000_000_000).dup
    range.define_singleton_method(:to_a) { raise "range materialized" }
    range.define_singleton_method(:each) { raise "range traversed" }
    assert_equal("23", render("{% for i in values offset: 1 limit: 2 %}{{ i }}{% endfor %}", { "values" => range }))
  end

  def test_invalid_loop_limit
    ['"bad"', "2.5"].each do |limit|
      assert_raises(Liquid::ArgumentError) { render("{% for i in (1..3) limit: #{limit} %}{{ i }}{% endfor %}") }
    end
  end

  def test_invalid_utf8_source
    ["\xC0", "\xE0\x01", "\xE0", "\xF0\x01\x01", "\xF0\x01", "\xF0"].each do |bytes|
      assert_raises(Liquid::TemplateEncodingError) { parse("{{ #{bytes} }}") }
    end
  end

  def test_profile_produces_ruby_tree
    require "liquid/profiler"
    template = parse("{{ title }}", profile: true)
    assert_equal("T", template.render!("title" => "T"))
    assert_instance_of(Liquid::BlockBody, template.root.body)
    assert_operator(template.profiler.total_render_time, :>=, 0)
  end

  def test_visitor_with_explicit_ruby_nodes
    template = parse("A{{ x }}{% assign y = x %}", disable_liquid_c_nodes: true)
    visitor = Liquid::ParseTreeVisitor.for(template.root)
    visitor.add_callback_for(Liquid::VariableLookup) { |node, _context| node.name }
    assert_equal(["x", "x"], visitor.visit.flatten.compact)
  end

  def test_global_custom_block
    Liquid::Environment.dangerously_override(@environment) do
      assert_equal("A<[T]ok>Z", render(
        "A{% buffer %}{% marker %}{{ x }}{% endbuffer %}Z",
        { "title" => "T", "x" => "ok" },
      ))
    end
  end

  def test_tokenizer_shift_is_public
    tokenizer = Liquid::ParseContext.new.new_tokenizer("text")
    assert_equal("text", tokenizer.shift)
  end

  def test_nul_is_preserved_in_syntax_error
    error = assert_raises(Liquid::SyntaxError) { parse("{{ x\0y }}", error_mode: :strict) }
    assert_includes(error.message, "Unexpected character \0 in")
  end

  def test_self_lookup_in_default_mode
    assert_equal("ok", render("{{ self.title }}", { "title" => "ok" }))
  end

  def test_environment_tag_lookup
    assert_equal("[T]", render("{% marker %}", { "title" => "T" }))
  end

  def test_repeated_registration_of_same_filter
    @environment.register_filter(Compatibility::Filters)
    @environment.register_filter(Compatibility::Filters)
    assert_equal("a!", render('{{ "a" | probe }}'))
  end

  def test_filter_options_are_fresh_and_mutable
    filter = Module.new do
      def consume_option(input, options = {})
        "#{input}:#{options.delete("label")}"
      end
    end
    @environment.register_filter(filter)
    template = parse('{{ "x" | consume_option: label:"ok" }}')
    assert_equal("x:ok", template.render!)
    assert_equal("x:ok", template.render!)
  end

  def test_lru_expression_cache
    require "lru_redux"
    cache = LruRedux::Cache.new(5)
    context = Liquid::ParseContext.new(error_mode: :strict, expression_cache: cache)
    first = context.parse_expression("title")
    assert_same(first, context.parse_expression("title"))
    assert_equal(1, cache.count)
  end

  def test_explicit_unsafe_expression_flag
    context = Liquid::ParseContext.new(error_mode: :strict2)
    assert_raises(Liquid::InternalError) { context.parse_expression("title", safe: false) }
  end

  def test_whitespace_compatibility_option
    source = "{% if true %}left{% endif %}\t {{- '' -}} right"
    assert_equal("left\tright", render(source, {}, bug_compatible_whitespace_trimming: true))
    assert_equal("leftright", render(source, {}, bug_compatible_whitespace_trimming: false))
  end

  def test_repeated_template_render_has_fresh_assigns
    template = parse("{{ title }}{% assign title = 'changed' %}")
    assert_equal("first", template.render!("title" => "first"))
    assert_equal("second", template.render!("title" => "second"))
  end

  def test_hash_output_keeps_liquid_format
    value = { "title" => "Товар" }
    assert_equal('{"title"=>"Товар"}', render("{{ value }}", { "value" => value }))
  end

  [:render_score_limit, :assign_score_limit, :render_length_limit].each do |attribute|
    define_method("test_#{attribute}_can_be_disabled") do
      limits = Liquid::ResourceLimits.new(attribute => 1)
      limits.public_send("#{attribute}=", nil)
      assert_nil(limits.public_send(attribute))
    end

    define_method("test_#{attribute}_accepts_large_integer") do
      limits = Liquid::ResourceLimits.new(attribute => 2**100)
      assert_equal(2**100, limits.public_send(attribute))
    end
  end

  def test_nested_capture_restores_outer_accounting
    limits = Liquid::ResourceLimits.new(assign_score_limit: 10)
    limits.with_capture do
      limits.increment_write_score("é")
      limits.with_capture { limits.increment_write_score("a") }
      limits.increment_write_score("éb")
    end
    assert_equal(4, limits.assign_score)
  end

  def test_dynamic_proc_is_evaluated_once
    calls = 0
    assigns = {
      "value" => -> {
        calls += 1
        "ok"
      },
    }
    assert_equal("okok", render("{{ value }}{{ value }}", assigns))
    assert_equal(1, calls)
  end

  private

  def parse(source, **options)
    Liquid::Template.parse(source, environment: @environment, error_mode: Compatibility::MODE, **options)
  end

  def render(source, assigns = {}, **options)
    parse(source, **options).render!(assigns)
  end
end
