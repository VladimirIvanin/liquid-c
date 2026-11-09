# frozen_string_literal: true

require "json"
require "rbconfig"

# An observer on another physical core avoids Ruby's GVL and the measured CPU.
module BenchmarkHostMetrics
  class << self
    def cpu_list(text)
      text.strip.split(",").flat_map do |part|
        part.include?("-") ? Range.new(*part.split("-").map(&:to_i)).to_a : [part.to_i]
      end
    end

    def read(path)
      File.read(path).strip
    rescue SystemCallError
      nil
    end

    def siblings(cpu)
      cpu_list(read("/sys/devices/system/cpu/cpu#{cpu}/topology/thread_siblings_list") || cpu.to_s)
    end

    def counters
      status = read("/proc/self/status").to_s
      fields = read("/proc/self/stat").to_s.split(") ", 2).last.to_s.split
      {
        minor_faults: fields[7].to_i,
        major_faults: fields[9].to_i,
        voluntary_switches: status[/^voluntary_ctxt_switches:\s+(\d+)/, 1].to_i,
        involuntary_switches: status[/^nonvoluntary_ctxt_switches:\s+(\d+)/, 1].to_i,
      }
    end

    def cpu_ticks(cpus)
      File.readlines("/proc/stat").filter_map do |line|
        next unless /\Acpu(\d+)\s/ =~ line && cpus.include?(Regexp.last_match(1).to_i)

        cpu = Regexp.last_match(1).to_i
        values = line.split.drop(1).map(&:to_i)
        [cpu.to_s, [values.first(8).sum, values[3] + values[4]]]
      end.to_h
    end

    def cgroup_stat
      path = read("/proc/self/cgroup").to_s.lines.find { |line| line.start_with?("0::") }&.strip&.delete_prefix("0::")
      file = path && File.join("/sys/fs/cgroup", path, "cpu.stat")
      text = file && read(file)
      text ||= read("/sys/fs/cgroup/cpu.stat")
      text.to_s.lines.to_h do |line|
        key, value = line.split
        [key, value.to_i]
      end
    end

    def observation(cpus)
      {
        monotonic: Process.clock_gettime(Process::CLOCK_MONOTONIC),
        unix_seconds: Time.now.to_f,
        ticks: cpu_ticks(cpus),
        frequency_khz: cpus.to_h do |cpu|
                         [cpu.to_s, read("/sys/devices/system/cpu/cpu#{cpu}/cpufreq/scaling_cur_freq")&.to_i]
                       end,
        thermal: cpus.flat_map do |cpu|
          Dir["/sys/devices/system/cpu/cpu#{cpu}/thermal_throttle/*throttle*"]
        end.to_h { |file| [file, read(file)&.to_i] },
        cgroup: cgroup_stat,
      }
    end

    def start
      return unless RUBY_PLATFORM.include?("linux") && ENV["BENCH_HOST_METRICS"] != "false"

      allowed = read("/proc/self/status").to_s[/^Cpus_allowed_list:\s+(.+)$/, 1]
      cpus = allowed && cpu_list(allowed)
      return unless cpus&.size == 1

      cpu = cpus.first
      group = siblings(cpu)
      observer = Dir["/sys/devices/system/cpu/cpu[0-9]*"].map { |path| path[/cpu(\d+)\z/, 1].to_i }.sort.find do |other|
        !group.include?(other)
      end
      return unless observer

      path = File.join(
        ENV.fetch("OUT_DIR"),
        "host-#{Process.pid}-#{Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)}.jsonl",
      )
      command = ["taskset", "-c", observer.to_s, RbConfig.ruby, "--disable-gems", __FILE__, cpu.to_s]
      pid = Process.spawn({ "RUBYOPT" => nil }, *command, out: path, err: path + ".stderr")
      { cpu: cpu, siblings: group, observer_cpu: observer, path: path, pid: pid }
    end

    def finish(observer, samples)
      return { available: false } unless observer

      status = stop(observer)
      raise "host observer failed" unless status.success?

      trace = File.readlines(observer.fetch(:path)).map { |line| JSON.parse(line) }
      samples.each do |sample|
        first = trace.reverse.find { |row| row.fetch("monotonic") <= sample.fetch(:monotonic_begin) }
        last = trace.find { |row| row.fetch("monotonic") >= sample.fetch(:monotonic_end) }
        if first && last
          busy = observer.fetch(:siblings).reject { |cpu| cpu == observer.fetch(:cpu) }.map do |cpu|
            a = first.fetch("ticks").fetch(cpu.to_s)
            b = last.fetch("ticks").fetch(cpu.to_s)
            total = b[0] - a[0]
            total.positive? ? 1.0 - (b[1] - a[1]).fdiv(total) : 0.0
          end.max || 0.0
          frequencies = trace.select do |row|
            row.fetch("monotonic").between?(first.fetch("monotonic"), last.fetch("monotonic"))
          end.filter_map { |row| row.fetch("frequency_khz")[observer.fetch(:cpu).to_s] }
          sample[:frequency_khz_range] = frequencies.minmax
          sample[:smt_sibling_busy_fraction] = busy
          sample[:isolation_ok] = busy <= 0.01 + Float::EPSILON &&
            first.fetch("cgroup").fetch("throttled_usec", 0) == last.fetch("cgroup").fetch("throttled_usec", 0) &&
            first.fetch("thermal") == last.fetch("thermal")
          sample[:cgroup_throttled_usec] =
            last.fetch("cgroup").fetch("throttled_usec", 0) - first.fetch("cgroup").fetch("throttled_usec", 0)
        else
          sample[:isolation_ok] = false
        end
      end
      directory = "/sys/devices/system/cpu/cpu#{observer.fetch(:cpu)}/cpufreq"
      observer.reject { |key, _| key == :pid }.merge(
        available: true,
        sibling_busy_limit: 0.01,
        governor: read(File.join(directory, "scaling_governor")),
        energy_preference: read(File.join(directory, "energy_performance_preference")),
      )
    end

    def stop(observer)
      return unless observer && (pid = observer.delete(:pid))

      Process.kill("TERM", pid)
      Process.waitpid2(pid).last
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end

    def observe(cpu)
      stop = false
      Signal.trap("TERM") { stop = true }
      cpus = siblings(cpu)
      $stdout.sync = true
      loop do
        puts JSON.generate(observation(cpus))
        break if stop

        sleep(0.1)
      end
    end
  end
end

BenchmarkHostMetrics.observe(Integer(ARGV.fetch(0))) if $PROGRAM_NAME == __FILE__
