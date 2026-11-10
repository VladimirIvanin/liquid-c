# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "rbconfig"
require_relative "process_runner"

class CompatibilityHarnessTest < Minitest::Test
  def test_failure_is_not_reported_as_success
    result = run_process('warn "failed"; exit 7')
    assert_equal(7, result[:exitstatus])
    refute(result[:success])
    refute(result[:timeout])
  end

  def test_signal_is_recorded
    result = run_process('Process.kill("TERM", Process.pid)')
    assert_equal(Signal.list.fetch("TERM"), result[:signal])
    refute(result[:success])
  end

  def test_hanging_child_is_terminated
    result = run_process("sleep 60", timeout: 0.1)
    assert(result[:timeout])
    refute(result[:success])
  end

  def test_environment_does_not_leak_to_parent
    previous = ENV["LIQUID_PARSER_MODE"]
    result = run_process('abort unless ENV["LIQUID_PARSER_MODE"] == "warn"')
    assert(result[:success])
    assert_equal([previous], [ENV["LIQUID_PARSER_MODE"]])
  end

  private

  def run_process(code, timeout: 5)
    Dir.mktmpdir("liquid-c-harness") do |directory|
      Compatibility::ProcessRunner.run(
        [RbConfig.ruby, "-e", code],
        env: { "LIQUID_PARSER_MODE" => "warn" },
        log: File.join(directory, "child.log"),
        timeout: timeout,
      )
    end
  end
end
