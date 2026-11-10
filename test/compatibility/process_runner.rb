# frozen_string_literal: true

require "fileutils"
require "json"
require "shellwords"

module Compatibility
  module ProcessRunner
    class << self
      def run(command, env:, log:, timeout:, spawn_options: {})
        FileUtils.mkdir_p(File.dirname(log))
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        pid = Process.spawn(env, *command, out: log, err: [:child, :out], pgroup: true, **spawn_options)
        status = nil
        timed_out = false
        loop do
          finished = Process.waitpid2(pid, Process::WNOHANG)
          if finished
            status = finished.last
            break
          end
          if Process.clock_gettime(Process::CLOCK_MONOTONIC) - started > timeout
            timed_out = true
            signal_group("TERM", pid)
            sleep(0.2)
            signal_group("KILL", pid)
            status = Process.waitpid2(pid).last
            break
          end
          sleep(0.05)
        end
        output = File.binread(log).force_encoding(Encoding::UTF_8).scrub
        {
          command: command.shelljoin,
          env: env,
          log: log,
          exitstatus: status.exitstatus,
          signal: status.termsig,
          timeout: timed_out,
          seconds: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(3),
          summary: output.scan(/\d+ runs, \d+ assertions, \d+ failures, \d+ errors, \d+ skips/).last,
          success: status.success? && !timed_out,
        }
      end

      def signal_group(signal, pid)
        Process.kill(signal, -pid)
      rescue Errno::ESRCH
        0
      end
    end
  end
end
