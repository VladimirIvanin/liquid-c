# frozen_string_literal: true

require "bundler/setup"
require "liquid"
require_relative "slice_fixtures"

if ENV["SLICE_PRELOAD"] == "true"
  Compatibility::LazySliceDrop.prepend(Compatibility::SlicePrefixPatch)
  Liquid::Utils.singleton_class.prepend(Compatibility::SliceUtilsPatch)
end

require_relative "boot"
require_relative "fixtures"
require_relative "process_runner"
require "minitest/autorun"
require "tmpdir"

class SliceCompatibilityTest < Minitest::Test
  def setup
    @environment = Liquid::Environment.build(error_mode: Compatibility::MODE).dup
    @drop = Compatibility::LazySliceDrop.new
    @context = Liquid::Context.build(environment: @environment, environments: { "items" => @drop, "prefix" => "A" })
  end

  {
    limit: ["limit: 2", 0, 2, "ab"],
    offset_limit: ["offset: 1 limit: 2", 1, 3, "bc"],
    offset: ["offset: 1", 1, nil, "bcd"],
    zero_limit: ["limit: 0", 0, 0, ""],
    beyond_end: ["offset: 9 limit: 2", 9, 11, ""],
    negative_offset: ["offset: -1 limit: 3", -1, 2, "ab"],
    negative_limit: ["limit: -1", 0, -1, ""],
    huge_offset: ["offset: 9223372036854775808 limit: 1", 2**63, 2**63 + 1, ""],
  }.each do |name, (attributes, from, to, expected)|
    define_method("test_for_#{name}") do
      @drop.forbid_each = true
      assert_equal(expected, parse(loop_source(attributes)).render!(@context))
      assert_equal([[:load_slice, from, to, "A"]], @drop.events)
    end

    define_method("test_tablerow_#{name}") do
      @drop.forbid_each = true
      source = "{% tablerow x in items #{attributes} cols: 2 %}{{ x }}{% endtablerow %}"
      output = parse(source).render!(@context)
      assert_equal(expected.chars, output.scan(%r{<td[^>]*>(.*?)</td>}m).flatten)
      assert_equal([[:load_slice, from, to, "A"]], @drop.events)
    end
  end

  def test_unbounded_iteration_uses_each
    assert_equal("abcd", parse(loop_source).render!(@context))
    assert_equal([[:each, "A"]], @drop.events)
    assert_equal(
      ["a", "b", "c", "d"],
      parse("{% tablerow x in items cols: 2 %}{{ x }}{% endtablerow %}").render!(@context)
        .scan(%r{<td[^>]*>(.*?)</td>}m).flatten,
    )
    assert_equal([[:each, "A"]] * 2, @drop.events)
  end

  def test_empty_loader_and_else
    @context["items"] = Compatibility::LazySliceDrop.new([])
    assert_equal("empty", parse("{% for x in items limit: 2 %}bad{% else %}empty{% endfor %}").render!(@context))
  end

  def test_variable_bounds_reversal_and_metadata
    @context["start"] = "1"
    @context["count"] = "2"
    source = "{% for x in items reversed offset: start limit: count %}" \
      "{{ x }}:{{ forloop.index }}/{{ forloop.length }}:{{ forloop.first }}:{{ forloop.last }};{% endfor %}"
    assert_equal("c:1/2:true:false;b:2/2:false:true;", parse(source).render!(@context))
    assert_equal([[:load_slice, 1, 3, "A"]], @drop.events)
  end

  def test_continue_offset_uses_selected_length_after_break
    first = "{% for x in items limit: 2 %}{{ x }}{% break %}{% endfor %}"
    second = loop_source("offset: continue limit: 2")
    template = parse("#{first}|#{second}")
    2.times { assert_equal("a|cd", template.render!(@context)) }
    assert_equal([0, 2, 0, 2], @drop.events.map { |event| event[1] })
    assert_empty(@context.registers[:for_stack])
  end

  def test_partial_contexts_and_repeated_render
    @environment.file_system = Compatibility::FileSystem.new("piece" => loop_source("offset: 1 limit: 2"))
    @context.registers[:file_system] = @environment.file_system
    template = parse("{% include 'piece' %}|{% render 'piece', items: items, prefix: 'child' %}")
    2.times { assert_equal("bc|bc", template.render!(@context)) }
    assert_equal(["A", "child", "A", "child"], @drop.events.map(&:last))
  end

  def test_loader_failure_does_not_poison_next_render
    template = parse("before#{loop_source("limit: 2")}after")
    @drop.failure = true
    error = assert_raises(Liquid::ArgumentError) { template.render!(@context) }
    assert_includes(error.message, "slice failed")
    assert_equal(1, @context.scopes.length)
    assert_nil(@context.registers[:for_stack])
    @drop.failure = false
    assert_equal("beforeabafter", template.render!(@context))
    assert_empty(@context.registers[:for_stack])
  end

  def test_loader_can_reenter_render
    nested = parse("[{{ prefix }}]")
    @drop.callback = ->(context) { context["nested"] = nested.render!(context) }
    assert_equal("ab|[A]", parse("#{loop_source("limit: 2")}|{{ nested }}").render!(@context))
    assert_empty(@context.registers[:for_stack])
  end

  ["before_compile", "after_compile", "after_render"].each do |timing|
    define_method("test_drop_patch_#{timing}") do
      source = "{% for x in items offset: 1 limit: 2 %}{{ x }}{% unless forloop.last %},{% endunless %}{% endfor %}"
      template = parse(source) unless timing == "before_compile"
      assert_equal("b,c", template.render!(@context)) if timing == "after_render"
      with_patch(Compatibility::LazySliceDrop, Compatibility::SlicePrefixPatch) do
        template ||= parse(source)
        assert_equal("A:b,A:c", template.render!(@context))
        @context["prefix"] = "B"
        assert_equal("B:b,B:c", template.render!(@context))
      end
      assert_equal("b,c", template.render!(@context))
      assert_equal(2, @drop.events.count { |event| event.first == :patch })
    end

    define_method("test_utils_patch_#{timing}") do
      template = parse(loop_source) unless timing == "before_compile"
      assert_equal("abcd", template.render!(@context)) if timing == "after_render"
      @drop.events.clear
      @drop.forbid_each = true
      with_patch(Liquid::Utils.singleton_class, Compatibility::SliceUtilsPatch) do
        template ||= parse(loop_source)
        2.times { assert_equal("abcd", template.render!(@context)) }
        assert_equal([[:load_slice, 0, nil, "A"]] * 2, @drop.events)
        assert_equal("12", template.render!("items" => [1, 2]))
      end
      @drop.forbid_each = false
      assert_equal("abcd", template.render!(@context))
      assert_equal(:each, @drop.events.last.first)
    end
  end

  def test_singleton_loader_is_resolved_again_and_can_be_removed
    template = parse(loop_source("limit: 2"))
    assert_equal("ab", template.render!(@context))
    @drop.define_singleton_method(:load_slice) { |from, to| super(from, to).map(&:upcase) }
    assert_equal("AB", template.render!(@context))
    @drop.singleton_class.remove_method(:load_slice)
    assert_equal("ab", template.render!(@context))
  end

  def test_patches_before_extension_load
    Dir.mktmpdir("liquid-slice") do |directory|
      result = Compatibility::ProcessRunner.run(
        [RbConfig.ruby, "-Ilib", __FILE__, "--name", "test_preloaded_slice_contract"],
        env: { "SLICE_PRELOAD" => "true" },
        log: File.join(directory, "preload.log"),
        timeout: 10,
      )
      assert(result[:success], File.read(result[:log]))
    end
  end

  if ENV["SLICE_PRELOAD"] == "true"
    def test_preloaded_slice_contract
      @drop.forbid_each = true
      assert_equal("A:aA:bA:cA:d", parse(loop_source).render!(@context))
      assert_equal([[:patch, 0, nil, "A"], [:load_slice, 0, nil, "A"]], @drop.events)
      assert_equal("12", parse(loop_source).render!("items" => [1, 2]))
    end
  end

  private

  def loop_source(attributes = "")
    "{% for x in items #{attributes} %}{{ x }}{% endfor %}"
  end

  def parse(source)
    Liquid::Template.parse(source, environment: @environment, error_mode: Compatibility::MODE)
  end

  def with_patch(target, source)
    patch = source.dup
    target.prepend(patch)
    yield
  ensure
    patch&.instance_methods(false)&.each { |name| patch.remove_method(name) }
  end
end
