# frozen_string_literal: true

require_relative "interop_helper"

# Threaded job servers (Sidekiq concurrency), pre-fork servers (Unicorn) and
# fibers (Enumerator#next, Async-style schedulers) create situations in which
# native state is shared, copied or abandoned.
class ConcurrencyTest < Minitest::Test
  include InteropHelper

  def test_threads_parse_and_render_while_another_thread_compacts
    done = false
    compactor = Thread.new do
      compact_fragmented_heap(rounds: 1) until done
    end if GC.respond_to?(:verify_compaction_references)

    template = Liquid::Template.parse(SOURCE)
    workers = Array.new(6) do
      Thread.new do
        Array.new(25) do
          [render_source, template.render!(ASSIGNS)]
        end.flatten
      end
    end
    outputs = workers.flat_map(&:value)
    done = true
    compactor&.join

    assert_equal([expected_output], outputs.uniq)
  end

  def test_pre_fork_child_renders_and_compacts_inherited_templates
    skip("fork is unavailable") unless Process.respond_to?(:fork)

    template = Liquid::Template.parse(SOURCE)
    pid = fork do
      ok = begin
        compact_fragmented_heap(rounds: 1)
        template.render!(ASSIGNS) == expected_output && render_source == expected_output
      rescue Exception # rubocop:disable Lint/RescueException
        false
      end
      exit!(ok ? 0 : 1)
    end
    _, status = Process.wait2(pid)
    assert_predicate(status, :success?)
    assert_equal(expected_output, template.render!(ASSIGNS))
  end

  def test_abandoned_fiber_in_the_middle_of_a_render
    parked = Module.new do
      def park(input)
        Fiber.yield(:parked)
        input
      end
    end
    template = Liquid::Template.parse("{% for i in (1..2) %}{{ i | park }}{% endfor %}")
    fiber = Fiber.new { template.render({}, filters: [parked]) }
    assert_equal(:parked, fiber.resume)
    GC.start
    compact_fragmented_heap(rounds: 1)
    GC.start

    # The abandoned render must not leave state that breaks later renders.
    assert_equal(expected_output, Liquid::Template.parse(SOURCE).render!(ASSIGNS))
  end

  def test_fiber_switch_into_the_same_context_raises_instead_of_corrupting_memory
    parked = Module.new do
      def park(input)
        Fiber.yield(:parked)
        input
      end
    end
    context = Liquid::Context.new({ "value" => "v" })
    context.add_filters([parked])
    suspended = Fiber.new { Liquid::Template.parse("{{ value | park }}").render(context) }
    assert_equal(:parked, suspended.resume)

    other = Liquid::Template.parse("{{ value }}-{{ value }}")
    result = begin
      other.render(context)
    rescue StandardError => error
      error
    end
    # Either an exception or ordinary output is acceptable; a crash is not.
    assert(result.is_a?(StandardError) || result.is_a?(String))
    GC.start
    assert_equal(expected_output, render_source)
  end

  def test_enumerator_next_inside_a_drop_leaves_a_suspended_fiber
    drop = Class.new(Liquid::Drop) do
      def first_item
        @enumerator ||= [1, 2, 3].each
        @enumerator.next
      end
    end
    10.times do
      template = Liquid::Template.parse("{{ drop.first_item }}{{ drop.first_item }}")
      assert_equal("12", template.render!({ "drop" => drop.new }))
      GC.start
    end
    compact_fragmented_heap(rounds: 1)
    assert_equal(expected_output, render_source)
  end
end
