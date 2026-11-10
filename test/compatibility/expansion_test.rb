# frozen_string_literal: true

require_relative "boot"
require_relative "fixtures"
require "minitest/autorun"
require "minitest/mock"
require "timeout"
require "tmpdir"

class ExpansionCompatibilityTest < Minitest::Test
  class CustomHash < Hash
    def to_s
      "custom-hash"
    end
  end

  def setup
    @environment = Liquid::Environment.new
    @environment.error_mode = Compatibility::MODE
  end

  def test_variable_lookup_without_scanner
    lookup = Liquid::VariableLookup.parse("foo.bar")
    assert_equal("foo", lookup.name)
    assert_equal(["bar"], lookup.lookups)
    assert_equal("value", Liquid::Context.new("foo" => { "bar" => "value" }).evaluate(lookup))
  end

  def test_dotted_filter_properties_are_literal_keys_on_nonempty_arrays
    nested = [{ "id" => "nested", "title" => { "content" => "wanted" } }]
    literal = nested + [{ "id" => "literal", "title.content" => "wanted" }]
    {
      "where" => ["| map: 'id' | join: ','", "", "literal"],
      "find" => ["| map: 'id' | join: ','", "", "literal"],
      "find_index" => ["", "", "1"],
      "has" => ["", "false", "true"],
      "reject" => ["| map: 'id' | join: ','", "nested", "nested"],
    }.each do |filter, (tail, absent, present)|
      source = "{{ items | #{filter}: 'title.content', 'wanted' #{tail} }}"
      assert_equal(absent, parse(source).render!("items" => nested), filter)
      assert_equal(present, parse(source).render!("items" => literal), filter)
    end
  end

  def test_hash_subclass_to_s_is_used_by_variable_and_capture
    value = CustomHash["title" => "ignored"]
    assert_equal(
      "custom-hash|custom-hash",
      parse("{{ x }}|{% capture y %}{{ x }}{% endcapture %}{{ y }}").render!("x" => value),
    )
    assert_equal('{"title"=>"ignored"}', parse("{{ x }}").render!("x" => { "title" => "ignored" }))
  end

  def test_cycle_named_query_distinguishes_lookup_and_literal_cycles
    context = Liquid::ParseContext.new(environment: @environment, error_mode: Compatibility::MODE)
    assert(Liquid::Cycle.parse("cycle", "'group': a, b", nil, context).named?)
    assert(Liquid::Cycle.parse("cycle", "'a', 'b'", nil, context).named?)
    refute(Liquid::Cycle.parse("cycle", "a, b", nil, context).named?)
  end

  def test_nested_output_is_counted_once_at_the_byte_boundary
    ["abcd", "ёж"].each do |text|
      source = "{% if true %}{% unless false %}#{text}{% endunless %}{% endif %}"
      template = parse(source)
      template.resource_limits.render_length_limit = text.bytesize
      assert_equal(text, template.render!)
      template.resource_limits.render_length_limit = text.bytesize - 1
      assert_raises(Liquid::MemoryError) { template.render! }
    end
  end

  def test_snippet_remains_unknown
    error = assert_raises(Liquid::SyntaxError) { parse("{% snippet %}") }
    assert_includes(error.message, "Unknown tag 'snippet'")
  end

  def test_inline_comment_error_starts_after_leading_markup_whitespace
    ["{% #\nfoo\nbar %}", "{%\n#\nfoo\nbar %}"].each_with_index do |source, index|
      error = assert_raises(Liquid::SyntaxError) { parse(source) }
      assert_equal(index + 2, error.line_number)
      assert_includes(error.message, "line #{index + 2}")
    end
  end

  def test_deprecated_api_warns_once_with_replacement_and_call_site
    previous_environment = Liquid::Environment.default
    previous_warned = Liquid::Deprecations.warned
    Liquid::Environment.instance_variable_set(:@default, Liquid::Environment.new)
    Liquid::Deprecations.warned = Set.new
    operations = {
      "register_tag" => ["Environment#register_tag", ["marker", Compatibility::MarkerTag]],
      "register_filter" => ["Environment#register_filter", [Compatibility::Filters]],
      "error_mode=" => ["Environment#error_mode=", [:strict]],
      "file_system=" => ["Environment#file_system=", [Compatibility::FileSystem.new]],
      "default_resource_limits=" => ["Environment#default_resource_limits=", [{}]],
    }
    operations.each do |name, (alternative, arguments)|
      warnings = []
      Warning.stub(:warn, ->(message) { warnings << message }) do
        2.times { Liquid::Template.send(name, *arguments) }
      end
      assert_equal(1, warnings.size, name)
      prefix = "[DEPRECATION] Template.#{name} is deprecated. Use #{alternative} instead."
      assert_match(/\A#{Regexp.escape(prefix)} Called from .*expansion_test\.rb:\d+.*\n\z/, warnings.first)
    end
    warnings = []
    Warning.stub(:warn, ->(message) { warnings << message }) do
      2.times do
        assert_raises(Liquid::SyntaxError) { Liquid::Template.parse("{{ [key] }}", error_mode: :rigid) }
      end
    end
    assert_equal(1, warnings.size)
    assert_includes(warnings.first, ":rigid")
    assert_includes(warnings.first, ":strict2")
  ensure
    Liquid::Environment.instance_variable_set(:@default, previous_environment)
    Liquid::Deprecations.warned = previous_warned
  end

  def test_unicode_identifiers_follow_the_selected_parser
    assigns = { "描述" => "ok", "消息" => "привет", "产品列表" => [{ "名称" => "name" }] }
    ["{{ 描述 }}", "{{ 消息 | upcase }}"].each do |source|
      if [:strict, :strict2].include?(Compatibility::MODE)
        assert_raises(Liquid::SyntaxError) { parse(source) }
      else
        assert_equal("", parse(source).render!(assigns))
      end
    end
    assert_raises(Liquid::SyntaxError) { parse("{% for 产品 in 产品列表 %}{{ 产品.名称 }}{% endfor %}") }
    assert_equal(
      "OK|name",
      parse("{{ ['描述'] | upcase }}|{{ ['产品列表'][0]['名称'] }}").render!(assigns),
    ) unless Compatibility::MODE == :strict2
    assert_equal("OK", parse("{{ data['描述'] | upcase }}").render!("data" => assigns))
  end

  def test_comparisons_do_not_treat_booleans_as_integers
    [">", "<", ">=", "<="].each do |operator|
      assert_equal("no", parse("{% if a #{operator} b %}yes{% else %}no{% endif %}").render!("a" => true, "b" => 2))
    end
    assert_equal("0..3", parse("{{ (empty..3) }}").render!)
  end

  def test_large_integer_literals_and_math_are_not_truncated
    integer = 2**63 + 1
    assert_equal((integer + 1).to_s, parse("{{ #{integer} | plus: 1 }}").render!)
    digits = "9" * 1000
    assert_equal((Integer(digits) + 1).to_s, parse("{{ '#{digits}' | plus: 1 }}").render!)
  end

  def test_empty_and_relative_partial_names_are_rejected_by_local_filesystem
    @environment.file_system = Liquid::LocalFileSystem.new(Dir.tmpdir)
    ["include", "render"].product(["", ".", "./"]).each do |tag, name|
      error = assert_raises(Liquid::FileSystemError) { parse("{% #{tag} '#{name}' %}").render! }
      assert_includes(error.message, "Illegal template name")
    end
  end

  def test_strict_variables_apply_to_conditions_and_before_default
    [
      "{% if missing %}yes{% endif %}",
      "{% unless missing %}yes{% endunless %}",
      "{% if false %}yes{% elsif missing %}yes{% endif %}",
      "{% if true and missing %}yes{% endif %}",
      "{{ missing | default: 'fallback' }}",
    ].each do |source|
      assert_raises(Liquid::UndefinedVariable) { parse(source).render!({}, strict_variables: true) }
    end
    assert_equal(
      "ok",
      parse("{% if false and missing %}bad{% else %}ok{% endif %}").render!({}, strict_variables: true),
    )
  end

  def test_dynamic_lookup_with_nonstring_keys
    unless Compatibility::MODE == :strict2
      [0, 2, false].each do |key|
        assert_equal("", parse("{{ [x] }}").render!({ "x" => key, key.to_s => "found" }))
        assert_equal("found", parse("{{ [x] }}").render!({ "x" => key, key => "found" }))
      end
      assert_equal("found", parse("{{ [[0]] }}").render!(0 => "key", "key" => "found"))
    end
    assert_equal("ok", parse("{{ values[key] }}").render!("values" => { false => "ok" }, "key" => false))
  end

  def test_include_with_expression_binds_the_template_name
    @environment.file_system = Compatibility::FileSystem.new("product" => "{{ product.name }}")
    assert_equal("other", parse("{% include 'product' with other %}").render!("other" => { "name" => "other" }))
  end

  def test_parallel_parses_and_render_can_overlap
    arrivals = Queue.new
    release = Queue.new
    parse_release = Queue.new
    gate = Class.new(Liquid::Tag) do
      define_method(:initialize) do |*arguments|
        super(*arguments)
        arrivals << :parse
        parse_release.pop
      end

      def render(_context)
        ""
      end
    end
    filter = Module.new do
      define_method(:wait_for_parse) do |input|
        arrivals << :render
        release.pop
        input
      end
    end
    @environment.register_filter(filter)
    @environment.register_tag("parse_gate", gate)
    template = parse("{{ value | wait_for_parse }}")
    threads = [Thread.new { template.render!("value" => "outer") }]
    begin
      Timeout.timeout(5) { arrivals.pop }
      2.times do |index|
        threads << Thread.new { parse("{% parse_gate %}{% assign x = #{index} %}{{ x }}").render! }
      end
      assert_equal([:parse, :parse], Timeout.timeout(5) { [arrivals.pop, arrivals.pop] })
      2.times { parse_release << true }
      assert_equal(["0", "1"], Timeout.timeout(5) { threads.drop(1).map(&:value) })
      release << true
      assert_equal("outer", Timeout.timeout(5) { threads.first.value })
      assert_equal("after", parse("{{ value }}").render!("value" => "after"))
    ensure
      threads.each { |thread| thread.kill if thread.alive? }
      threads.each(&:join)
    end
  end

  private

  def parse(source)
    Liquid::Template.parse(source, environment: @environment, error_mode: Compatibility::MODE, line_numbers: true)
  end
end
