# frozen_string_literal: true

require_relative "interop_helper"

# Process.warmup (called at boot by job servers such as Sidekiq 7.3.6+) and
# GC.compact move every object that is not pinned. Native state must not keep
# addresses of moved objects.
class RuntimeWarmupTest < Minitest::Test
  include InteropHelper

  def test_process_warmup_between_parse_and_render
    skip("Process.warmup is unavailable") unless Process.respond_to?(:warmup)

    template = Liquid::Template.parse(SOURCE)
    Process.warmup
    assert_equal(expected_output, template.render!(ASSIGNS))
    assert_native_paths_work
  end

  def test_native_classes_survive_compaction
    skip("GC compaction is unavailable") unless GC.respond_to?(:verify_compaction_references)

    template = Liquid::Template.parse(SOURCE)
    before = native_class_addresses
    moved = false
    5.times do
      break unless compact_fragmented_heap

      moved ||= native_class_addresses != before
      assert_equal(expected_output, template.render!(ASSIGNS))
      assert_native_paths_work
    end
    # Whether a class moves depends on the heap layout; the assertions above
    # are what protect against stale native references when it does.
    puts "native classes moved during compaction: #{moved}" if ENV["VERBOSE"]
  end

  def test_compaction_during_render
    skip("GC compaction is unavailable") unless GC.respond_to?(:verify_compaction_references)

    helper = self
    filters = Module.new do
      define_method(:compact_now) do |input|
        helper.compact_fragmented_heap(rounds: 1)
        input
      end
    end
    source = "{% for i in (1..3) %}{{ i | compact_now }}{% raw %}-{% endraw %}{% endfor %}{{ 'x' | compact_now }}"
    assert_equal("1-2-3-x", Liquid::Template.parse(source).render!({}, filters: [filters]))
  end

  def test_auto_compaction_while_parsing_and_rendering
    skip("GC compaction is unavailable") unless GC.respond_to?(:auto_compact=)
    skip("automatic compaction crashes MRI itself before Ruby 3.3") if RUBY_VERSION < "3.3"

    previous = GC.auto_compact
    GC.auto_compact = true
    begin
      40.times do
        compact_fragmented_heap(rounds: 1) if GC.respond_to?(:verify_compaction_references)
        assert_equal(expected_output, render_source)
      end
    ensure
      GC.auto_compact = previous
    end
  end
end
