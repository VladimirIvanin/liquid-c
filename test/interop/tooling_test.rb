# frozen_string_literal: true

require_relative "interop_helper"

# Profilers, tracers and heap inspection tools that observe a live process:
# StackProf, Sentry/OpenTelemetry style TracePoint instrumentation,
# memory_profiler and ObjectSpace dumps.
class ToolingTest < Minitest::Test
  include InteropHelper

  def test_stackprof_sampling_during_parse_and_render
    begin
      require "stackprof"
    rescue LoadError
      skip("stackprof is unavailable")
    end

    outputs = nil
    StackProf.run(mode: :wall, interval: 200, raw: true) do
      outputs = Array.new(200) { render_source }
    end
    assert_equal([expected_output], outputs.uniq)
  end

  def test_tracepoint_instrumentation_does_not_change_output
    calls = 0
    trace = TracePoint.new(:call, :c_call, :return) { calls += 1 }
    output = trace.enable { render_source }
    assert_equal(expected_output, output)
    assert_operator(calls, :>, 0)
    assert_equal(expected_output, render_source)
  end

  def test_tracepoint_enabled_after_parse_and_before_render
    template = Liquid::Template.parse(SOURCE)
    trace = TracePoint.new(:call) {}
    output = trace.enable { template.render!(ASSIGNS) }
    assert_equal(expected_output, output)
  end

  def test_object_space_walks_with_live_templates
    templates = Array.new(20) { Liquid::Template.parse(SOURCE) }
    assert_operator(ObjectSpace.each_object(Class).count, :>, 0)
    assert_operator(ObjectSpace.memsize_of_all, :>, 0)
    File.open(File::NULL, "w") { |io| ObjectSpace.dump_all(output: io) }
    assert_equal([expected_output], templates.map { |template| template.render!(ASSIGNS) }.uniq)
  end

  def test_allocation_tracing_with_live_templates
    ObjectSpace.trace_object_allocations do
      assert_equal(expected_output, render_source)
    end
    ObjectSpace.trace_object_allocations_clear
  end
end
