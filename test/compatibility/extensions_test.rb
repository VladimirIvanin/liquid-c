# frozen_string_literal: true

require "bundler/setup"
require "liquid"
require_relative "extensions_fixtures"

if ENV["EXTENSIONS_PRELOAD"] == "true"
  Liquid::Variable.prepend(Compatibility::Extensions::VariableObserver)
  Liquid::ParseContext.prepend(Compatibility::Extensions::WhitespaceDefaults)
  Liquid::Environment.prepend(Compatibility::Extensions::ReloadableFilters)
end

require_relative "boot"
require_relative "fixtures"
require_relative "extensions_collection_fixtures"
require_relative "extensions_collection_cases"
require_relative "extensions_language_fixtures"
require_relative "extensions_language_cases"
require_relative "process_runner"
require "minitest/autorun"
require "tmpdir"
require "timeout"

class ExtensionsTest < Minitest::Test
  include CompatibilityCollectionCases
  include CompatibilityLanguageCases
  Extensions = Compatibility::Extensions

  def setup
    @environment = Liquid::Environment.new
    @environment.error_mode = Compatibility::MODE
    @environment.register_filter(Extensions::Filters)
    {
      "inspect_value" => Extensions::InspectTag,
      "store" => Extensions::StoreBlock,
      "recall" => Extensions::RecallTag,
      "nonblank" => Extensions::NonblankBlock,
      "slice_items" => Extensions::SliceBlock,
      "nested" => Extensions::NestedTag,
      "register_scope" => Extensions::RegisterBlock,
      "register_write" => Extensions::RegisterWriteTag,
      "cached_fragment" => Extensions::CachedFragmentTag,
      "component" => Extensions::ComponentBlock,
      "region" => Extensions::RegionBlock,
      "selection" => Extensions::SelectionBlock,
    }.each { |name, klass| @environment.register_tag(name, klass) }
  end

  def test_parse_context_injects_whitespace_default_and_respects_false
    with_patch(Liquid::ParseContext, Extensions::WhitespaceDefaults) do
      source = "{% if true %}left{% endif %}\t {{- '' -}} right\r\n"
      assert_equal("left\tright\r\n", parse(source).render!)
      assert_equal("leftright\r\n", parse(source, bug_compatible_whitespace_trimming: false).render!)
    end
  end

  def test_injected_whitespace_default_reaches_partial
    with_patch(Liquid::ParseContext, Extensions::WhitespaceDefaults) do
      @environment.file_system = Compatibility::FileSystem.new(
        "piece" => "{% if true %}left{% endif %}\t {{- '' -}} right\r\n",
      )
      template = parse("A{% include 'piece' %}Z")
      2.times { assert_equal("Aleft\tright\r\nZ", template.render!) }
      assert_equal(
        "Aleftright\r\nZ",
        parse("A{% include 'piece' %}Z", bug_compatible_whitespace_trimming: false).render!,
      )
    end
  end

  def test_for_syntax_constant_changes_lax_parser
    with_for_syntax(/\A(\w+)\s+within\s+(#{Liquid::QuotedFragment}+)\s*(reversed)?/o) do
      template = parse("{% for item within items %}{{ item }}{% endfor %}", error_mode: :lax)
      assert_equal("ab", template.render!("items" => ["a", "b"]))
      assert_raises(Liquid::SyntaxError) { parse("{% for item in items %}x{% endfor %}", error_mode: :lax) }
    end
  end

  def test_for_tail_and_hyphen_follow_selected_parser
    with_for_syntax(/\A(\w+)\s+in\s+(#{Liquid::QuotedFragment}+)\s*(reversed)?/o) do
      source = "{% for item in items trailing %}{{ item }}{% endfor %}"
      if [:lax, :warn].include?(Compatibility::MODE)
        template = parse(source)
        assert_equal("ab", template.render!("items" => ["a", "b"]))
        assert_equal(Compatibility::MODE == :warn ? 1 : 0, template.warnings.size)
        assert_raises(Liquid::SyntaxError) { parse("{% for some-item in items trailing %}x{% endfor %}") }
      else
        assert_raises(Liquid::SyntaxError) { parse(source) }
        assert_equal(
          "ab",
          parse("{% for some-item in items %}{{ some-item }}{% endfor %}").render!("items" => ["a", "b"]),
        )
      end
    end
  end

  def test_variable_hook_runs_before_filter
    with_patch(Liquid::Variable, Extensions::VariableObserver) { assert_observed_variable }
  end

  def test_variable_hook_installed_after_compilation
    template = parse("[{{ title | observed }}]")
    with_patch(Liquid::Variable, Extensions::VariableObserver) { assert_observed_variable(template) }
  end

  def test_patches_installed_before_extension_load
    Dir.mktmpdir("liquid-extensions") do |directory|
      result = Compatibility::ProcessRunner.run(
        [RbConfig.ruby, "-Ilib", __FILE__, "--name", "test_preloaded_patches_contract"],
        env: { "EXTENSIONS_PRELOAD" => "true" },
        log: File.join(directory, "preload.log"),
        timeout: 30,
      )
      assert(result[:success], File.read(result[:log]))
      assert_match(/1 runs, \d+ assertions, 0 failures, 0 errors, 0 skips/, result[:summary])
    end
  end

  if ENV["EXTENSIONS_PRELOAD"] == "true"
    def test_preloaded_patches_contract
      assert_observed_variable
      assert_equal("left\tright", parse("{% if true %}left{% endif %}\t {{- '' -}} right").render!)
      assert_reloaded_filters
    end
  end

  def test_tag_variable_returns_drop_and_output_uses_to_s
    drop = Extensions::DynamicDrop.new
    context = build_context({ "value" => drop })
    template = parse("{% inspect_value value %}|{{ value }}")
    2.times do
      assert_equal("drop:drop-text|drop-text", template.render!(context))
      assert_same(drop, context.registers[:tag_value])
    end
  end

  def test_nested_variable_from_filter_preserves_arguments
    with_patch(Liquid::Variable, Extensions::VariableObserver) do
      context = build_context({ "title" => "outer", "inner" => "inside" })
      context.registers[:observe_variables] = true
      template = parse("{{ title | nested_value: 'L', 'R' }}")
      2.times { assert_equal("L:outer:inside!:R", template.render!(context)) }
      assert_equal(4, context.registers[:observed_calls])
    end
  end

  def test_blank_block_stores_super_output_for_second_template
    first = parse("A{% store %}{{ title }}{% end_store %}Z")
    second = parse("B{% recall %}C")
    context = build_context({ "title" => "first" })
    ["first", "second"].each do |title|
      context["title"] = title
      assert_equal("AZ", first.render!(context))
      assert_equal("B#{title}C", second.render!(context))
    end
    assert_equal(2, context.registers[:store_calls])
  end

  def test_blank_and_nonblank_blocks_execute_inside_blank_parent
    template = parse("{% if true %}{% store %} {% end_store %}{% nonblank %}{% endnonblank %}{% endif %}")
    context = build_context
    assert_equal("[]", template.render!(context))
    assert_equal(1, context.registers[:store_calls])
    assert_equal(1, context.registers[:nonblank_calls])
  end

  def test_stack_slice_is_visible_in_loop_and_restored_outside
    items = Extensions::DynamicDrop.new
    context = build_context({ "items" => items })
    template = parse("{% slice_items %}{% for item in items %}{{ item }}{% endfor %}" \
      "{% endslice_items %}|{{ items.size }}")
    2.times { assert_equal("bc|4", template.render!(context)) }
    assert_same(items, context["items"])
    assert_includes(items.received, 1..2)
  end

  def test_stack_slice_is_restored_after_exception
    items = ["a", "b", "c"]
    context = build_context({ "items" => items, "fail" => true })
    template = parse("{% slice_items %}{{ 'argument' | fail_with }}{% endslice_items %}")
    assert_raises(Liquid::ArgumentError) { template.render!(context) }
    assert_same(items, context["items"])
    context["fail"] = false
    assert_equal("argument", template.render!(context))
    assert_same(items, context["items"])
  end

  def test_full_nested_template_uses_shared_context
    nested = parse("{{ title }}{% assign title = 'changed' %}")
    context = build_context({ "title" => "initial" })
    context.registers[:nested_template] = nested
    template = parse("A{% nested %}|{{ title }}Z")
    assert_equal("Ainitial|changedZ", template.render!(context))
    assert_equal("Achanged|changedZ", template.render!(context))
  end

  def test_overrides_apply_to_already_compiled_template
    template = parse("{{ 'ab' | replace: 'a', 'x' }}|{{ 'ab' | remove: 'a' }}|{{ '<' | escape }}|{{ 'ёж' | upcase }}")
    context = build_context
    assert_equal("xb|b|&lt;|ЁЖ", template.render!(context))
    @environment.register_filter(Extensions::Overrides)
    2.times { assert_equal("replace:xb|remove:b|escape:&lt;|upper:ЁЖ", template.render!(context)) }
  end

  def test_overrides_preserve_nil_arguments_and_strip_script
    @environment.register_filter(Extensions::Overrides)
    source = "{{ 'abc' | replace: nil, 'x' }}|{{ 'abc' | replace: 'a', nil }}|" \
      "{{ 'abc' | remove: nil }}|[{{ nil | escape }}]|{{ html | strip_html }}"
    template = parse(source)
    2.times do
      assert_equal(
        "abc|abc|abc|[]|hello world",
        template.render!("html" => "<script>bad()</script><b>hello&nbsp;world</b>"),
      )
    end
  end

  def test_decimal_conversion_is_used_by_filters_and_comparisons
    with_patch(Liquid::Utils.singleton_class, Extensions::DecimalConversion) do
      @environment.register_filter(Extensions::Overrides)
      number = Extensions::FloatValue.new
      assert_equal(BigDecimal("1.25"), Liquid::Utils.to_number(number))
      assert_instance_of(BigDecimal, Liquid::Utils.to_number("1.20"))
      template = parse("{{ number | round: 1 }}|{{ '1.20' | plus: '0.10' }}|" \
        "{% if decimal == number_value %}equal{% endif %}")
      2.times do
        assert_equal(
          "1.3|1.3|equal",
          template.render!("number" => number, "decimal" => BigDecimal("1.2"), "number_value" => 1.2),
        )
      end
    end
  end

  def test_filter_nil_and_safe_string_output
    template = parse("A{{ title | nothing }}B{{ title | safe_markup }}C")
    2.times { assert_equal("AB<b>T</b>C", template.render!("title" => "T")) }
    context = build_context({ "title" => "T" })
    value = Liquid::Variable.new("title | safe_markup", Liquid::ParseContext.new).render(context)
    assert_instance_of(Extensions::SafeString, value)
    assert_predicate(value, :html_safe?)
  end

  def test_splat_and_optional_hash_filters
    template = parse("{{ 'a' | collect: 'b', 'c', label: 'd' }}|" \
      "{{ 'a' | optional_options: 'b', label: 'c' }}|{{ 'a' | optional_options }}")
    2.times { assert_equal("a:b:c:d|abc|a!", template.render!) }
  end

  def test_filter_reload_rebuilds_strainer_with_new_arity
    with_patch(Liquid::Environment, Extensions::ReloadableFilters) { assert_reloaded_filters }
  end

  def test_dynamic_drop_keys_iteration_and_truthiness
    drop = Extensions::DynamicDrop.new
    context = build_context({ "items" => drop })
    template = parse("{{ items.title }}|{{ items[1] }}|{{ items.first }}{{ items.last }}:{{ items.size }}|" \
      "{% for item in items offset: 1 limit: 2 %}{{ item }}{% endfor %}|" \
      "{% if items.off %}bad{% else %}false{% endif %}:" \
      "{% if items.empty %}empty-truthy{% endif %}:[{{ items.absent }}]")
    2.times { assert_equal("dynamic|b|ad:4|bc|false:empty-truthy:[]", template.render!(context)) }
    assert_includes(drop.received, "title")
    assert_includes(drop.received, 1)
    assert_equal(false, drop.invoke_drop("off"))
    assert_nil(drop.invoke_drop("absent"))
    assert_equal("", drop.invoke_drop("empty"))
  end

  def test_drop_receives_updated_context_and_registers
    drop = Extensions::DynamicDrop.new
    context = build_context({ "items" => drop })
    context.registers[:scope] = "first"
    template = parse("{{ items.title }}")
    assert_equal("dynamic", template.render!(context))
    context["preload_limit"] = 7
    context.registers[:scope] = "second"
    assert_equal("dynamic", template.render!(context))
    assert_equal([nil, "first"], drop.snapshots.first)
    assert_equal([7, "second"], drop.snapshots.last)
  end

  def test_dynamic_drop_range_lookup_and_false_output
    drop = Extensions::DynamicDrop.new
    template = parse("{{ items[window] | join: ',' }}|{{ items.off }}:[{{ items.empty }}]:[{{ items.absent }}]")
    2.times { assert_equal("b,c|false:[]:[]", template.render!("items" => drop, "window" => (1..2))) }
    assert_includes(drop.received, 1..2)
  end

  def test_drop_json_and_serialization_failure
    template = parse("{{ value | json }}|{{ broken | json }}")
    2.times do
      assert_equal(
        "{}|{}",
        template.render!("value" => Extensions::DynamicDrop.new, "broken" => Extensions::BrokenJsonDrop.new),
      )
    end
  end

  def test_layered_registers_identity_fetch_and_stack_visibility
    registers = Liquid::Registers.new(scope: "static")
    context = build_context({}, registers: registers)
    template = parse("{{ 'x' | register_value }}|" \
      "{% register_scope %}{{ 'y' | register_value }}{% endregister_scope %}|{{ 'z' | register_value }}")
    2.times do
      assert_equal("x:static:fallback|y:local:fallback|z:static:fallback", template.render!(context))
      assert_same(registers, context.registers)
      assert_equal("static", registers.fetch(:scope))
      assert_equal("static", registers.static[:scope])
      refute_respond_to(registers, :dig)
    end
  end

  def test_static_registers_reach_include_and_render_local_writes_do_not_escape
    @environment.file_system = Compatibility::FileSystem.new("piece" => "{{ 'p' | register_value }}")
    registers = Liquid::Registers.new(scope: "static", file_system: @environment.file_system)
    context = build_context({}, registers: registers)
    template = parse("{% include 'piece' %}|" \
      "{% register_scope %}{% include 'piece' %}{% endregister_scope %}|{{ 'z' | register_value }}")
    2.times { assert_equal("p:static:fallback|p:local:fallback|z:static:fallback", template.render!(context)) }
    assert_same(registers, context.registers)
    child = context.new_isolated_subcontext
    child.registers[:scope] = "child"
    assert_equal("child", child.registers.fetch(:scope))
    assert_equal("static", registers.fetch(:scope))
  end

  def test_render_partial_keeps_register_writes_local
    @environment.file_system = Compatibility::FileSystem.new("piece" => "{% register_write %}")
    context = build_context({}, registers: { scope: "static" })
    template = parse("{% render 'piece' %}|{{ 'p' | register_value }}")
    2.times { assert_equal("static:child|p:static:fallback", template.render!(context)) }
    assert_equal("static", context.registers.fetch(:scope))
  end

  ["argument", "syntax", "file", "zero", "float", "cause"].each do |kind|
    define_method("test_error_renderer_#{kind}_and_recovery") do
      seen = []
      @environment.exception_renderer = lambda do |error|
        seen << [error.class.name, error.cause&.class&.name, error.line_number]
        "ERR:#{kind}:#{error.line_number}"
      end
      context = build_context({ "fail" => true })
      template = parse("Привет\nA{{ '#{kind}' | fail_with }}Z", line_numbers: true)
      assert_equal("Привет\nAERR:#{kind}:2Z", template.render(context))
      classes = {
        "argument" => "Liquid::ArgumentError",
        "syntax" => "Liquid::SyntaxError",
        "file" => "Liquid::FileSystemError",
        "zero" => "Liquid::ZeroDivisionError",
        "float" => "Liquid::FloatDomainError",
        "cause" => "Liquid::InternalError",
      }
      assert_equal(classes.fetch(kind), seen.fetch(0).fetch(0))
      assert_equal(2, seen.fetch(0).fetch(2))
      assert_equal("FloatDomainError", seen.fetch(0).fetch(1)) if kind == "cause"
      assert_equal(1, seen.size)
      assert_equal(1, template.errors.size)
      context["fail"] = false
      assert_equal("Привет\nA#{kind}Z", template.render(context))
      assert_equal(1, seen.size)
    end
  end

  def test_missing_partial_becomes_error_text
    @environment.exception_renderer = ->(error) { "ERR:#{error.class.name}:#{error.line_number}" }
    template = parse("До\nA{% include 'missing' %}Z", line_numbers: true)
    assert_equal("До\nAERR:Liquid::FileSystemError:2Z", template.render)
    assert_equal(1, template.errors.size)
    template.registers[:file_system] = Compatibility::FileSystem.new("missing" => "found")
    assert_equal("До\nAfoundZ", template.render)
  end

  def test_unknown_tag_warn_and_strict_report_cyrillic_line
    [:warn, :strict].each do |mode|
      error = assert_raises(Liquid::SyntaxError) do
        parse("Привет\n{% unknown_extension %}\nПосле", error_mode: mode, line_numbers: true)
      end
      assert_equal(2, error.line_number)
      assert_equal("Liquid syntax error (line 2): Unknown tag 'unknown_extension'", error.message)
    end
    assert_equal("живой", parse("{{ title }}").render!("title" => "живой"))
  end

  def test_shared_template_renders_in_two_overlapping_threads
    template = parse("A{{ title | rendezvous }}|{{ title | register_value }}Z")
    arrivals = Queue.new
    release = Queue.new
    contexts = ["one", "two"].map do |name|
      build_context({ "title" => name }, registers: { scope: name, arrivals: arrivals, release: release })
    end
    threads = contexts.map { |context| Thread.new { template.render!(context) } }
    begin
      participants = Timeout.timeout(5) { [arrivals.pop, arrivals.pop] }
      assert_equal(["one", "two"], participants.sort)
      2.times { release << true }
      outputs = Timeout.timeout(5) { threads.map(&:value) }
      assert_equal(["Aone:one|one:one:fallbackZ", "Atwo:two|two:two:fallbackZ"], outputs)
      contexts.each { |context| assert_empty(context.errors) }
    ensure
      threads.each { |thread| thread.kill if thread.alive? }
      threads.each(&:join)
    end
  end

  private

  def parse(source, **options)
    template = Liquid::Template.parse(source, environment: @environment, error_mode: Compatibility::MODE, **options)
    expected = Compatibility::ENGINE == "c" ? "Liquid::C::BlockBody" : "Liquid::BlockBody"
    assert_equal(expected, template.root.body.class.name)
    template
  end

  def build_context(assigns = {}, registers: {})
    Liquid::Context.build(environment: @environment, environments: assigns, registers: registers)
  end

  def with_patch(target, source)
    patch = source.dup
    target.prepend(patch)
    yield
  ensure
    patch&.instance_methods(false)&.each { |name| patch.remove_method(name) }
  end

  def with_for_syntax(syntax)
    original = Liquid::For::Syntax
    Liquid::For.send(:remove_const, :Syntax)
    Liquid::For.const_set(:Syntax, syntax)
    yield
  ensure
    Liquid::For.send(:remove_const, :Syntax)
    Liquid::For.const_set(:Syntax, original)
  end

  def assert_observed_variable(template = parse("[{{ title | observed }}]"))
    context = build_context({ "title" => "first" })
    context.registers[:observe_variables] = true
    assert_equal("[title:first]", template.render!(context))
    context["title"] = "second"
    assert_equal("[title:second]", template.render!(context))
    assert_equal(2, context.registers[:observed_calls])
  end

  def assert_reloaded_filters
    first = Module.new { def revision(input) = "old:#{input}" }
    second = Module.new { def revision(input, suffix) = "new:#{input}:#{suffix}" }
    Extensions.const_set(:ReloadFilter, first)
    @environment.register_filter(first)
    template = parse("{{ 'x' | revision }}")
    old_context = build_context
    assert_equal("old:x", template.render!(old_context))
    old_strainer = old_context.strainer
    Extensions.send(:remove_const, :ReloadFilter)
    Extensions.const_set(:ReloadFilter, second)
    @environment.register_filter(second)
    assert_equal("old:x", template.render!(old_context))
    assert_same(old_strainer, old_context.strainer)
    updated = parse("{{ 'x' | revision: 'y' }}")
    2.times { assert_equal("new:x:y", updated.render!(build_context)) }
    assert_raises(Liquid::ArgumentError) { template.render!(build_context) }
    assert_raises(Liquid::ArgumentError) { updated.render!(old_context) }
    assert_equal("old:x", template.render!(old_context))
  ensure
    Extensions.send(:remove_const, :ReloadFilter) if Extensions.const_defined?(:ReloadFilter, false)
  end
end
