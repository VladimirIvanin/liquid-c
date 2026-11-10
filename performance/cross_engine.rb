# frozen_string_literal: true

require "json"
require "digest"
require "rbconfig"
require_relative "host_metrics"
gem "strscan", ">= 3.1.0"
require "strscan"

configuration = JSON.parse(ENV.fetch("BENCH_CONFIGURATION"))
root = File.expand_path(configuration.fetch("liquid_root"))
$LOAD_PATH.unshift(File.join(root, "lib"))
require "liquid"
if configuration["expected_liquid"] && Liquid::VERSION != configuration.fetch("expected_liquid")
  raise "incorrect Liquid version: #{Liquid::VERSION}"
end

# A source checkout can be used without installing a second gem into Bundler.
Gem.loaded_specs["liquid"] ||= Gem::Specification.new do |spec|
  spec.name = "liquid"
  spec.version = Liquid::VERSION
  spec.instance_variable_set(:@full_gem_path, root)
end
if configuration["library"]
  $LOAD_PATH.unshift(File.expand_path(configuration.fetch("library")))
  $LOAD_PATH.unshift(File.expand_path(configuration.fetch("extension")))
  require "liquid/c"
  raise "C extension is disabled" unless Liquid::C.enabled
  if configuration["expected_liquid_c"] && Liquid::C::VERSION != configuration.fetch("expected_liquid_c")
    raise "incorrect liquid-c version: #{Liquid::C::VERSION}"
  end

  loaded = $LOADED_FEATURES.find { |path| path.end_with?("/liquid_c.so", "/liquid_c.bundle") }
  expected_extension = File.realpath(configuration.fetch("extension"))
  raise "incorrect C extension loaded: #{loaded}" unless File.dirname(File.realpath(loaded)) == expected_extension
end
raise "YJIT must be disabled" if defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?

BENCH_CONFIGURATION = configuration.freeze
LIQUID5 = Gem::Version.new(Liquid::VERSION) >= Gem::Version.new("5")
CLOCK = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }

def configure_error_mode(mode)
  if LIQUID5
    Liquid::Environment.default.error_mode = mode
  else
    Liquid::Template.error_mode = mode
  end
end

def engine_info
  extension = $LOADED_FEATURES.find { |path| path.end_with?("/liquid_c.so", "/liquid_c.bundle") }
  makefile = BENCH_CONFIGURATION["extension"] && File.join(BENCH_CONFIGURATION.fetch("extension"), "Makefile")
  build = File.binread(makefile) if makefile && File.file?(makefile)
  {
    variant: BENCH_CONFIGURATION.fetch("name"),
    recorded_at: Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
    harness_sha256: Digest::SHA256.hexdigest(
      [
        "cross_engine.rb",
        "cross_compare.rb",
        "cross_theme.rb",
        "cross_fixtures.rb",
        "workloads.rb",
        "fixtures.json",
        "host_metrics.rb",
      ].map do |name|
        name + "\0" + File.binread(File.join(__dir__, name))
      end.join("\0"),
    ),
    revision: BENCH_CONFIGURATION["revision"],
    liquid: Liquid::VERSION,
    liquid_c: defined?(Liquid::C::VERSION) && Liquid::C::VERSION,
    ruby: RUBY_DESCRIPTION,
    yjit: false,
    strscan: StringScanner::Version,
    cpu_model: File.exist?("/proc/cpuinfo") && File.read("/proc/cpuinfo")[/^model name\s*:\s*(.+)$/, 1],
    cpu_affinity: File.exist?("/proc/self/status") && File.read("/proc/self/status")[/^Cpus_allowed_list:\s+(.+)$/, 1],
    native_switches: ENV.select { |key, _| key.start_with?("LIQUID_C_NATIVE_") },
    extension: extension,
    extension_sha256: extension && Digest::SHA256.file(extension).hexdigest,
    configuration: BENCH_CONFIGURATION,
    compiler: RbConfig::CONFIG.values_at("CC", "CFLAGS", "optflags"),
    build_flags: build&.lines&.grep(
      /\A(?:CC|CFLAGS|CPPFLAGS|LDFLAGS|DLDFLAGS|cflags|optflags|debugflags|warnflags|CCDLFLAGS|ARCH_FLAG)\s*=/,
    ),
    build_makefile_sha256: build && Digest::SHA256.hexdigest(build),
  }
end

def measure(operation, warmup:, batch:, repeats:)
  GC.enable
  observer = BenchmarkHostMetrics.start
  deadline = CLOCK.call + warmup
  operation.call while CLOCK.call < deadline
  samples = Array.new(repeats) do
    GC.start
    host_before = BenchmarkHostMetrics.counters
    process_before = Process.times
    unix_begin = Time.now.to_f
    before = GC.stat
    count = 0
    cpu_started = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID)
    started = CLOCK.call
    deadline = started + batch
    loop do
      operation.call
      count += 1
      break if CLOCK.call >= deadline
    end
    elapsed = CLOCK.call - started
    cpu_elapsed = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID) - cpu_started
    after = GC.stat
    unix_end = Time.now.to_f
    process_after = Process.times
    host_after = BenchmarkHostMetrics.counters
    {
      seconds: elapsed / count,
      monotonic_begin: started,
      monotonic_end: started + elapsed,
      unix_begin: unix_begin,
      unix_end: unix_end,
      user_seconds: (process_after.utime - process_before.utime) / count,
      system_seconds: (process_after.stime - process_before.stime) / count,
      host_counters_delta: host_before.to_h { |key, value| [key, host_after.fetch(key) - value] },
      cpu_seconds: cpu_elapsed / count,
      cpu_utilization: cpu_elapsed / elapsed,
      gc_seconds: (after.fetch(:time, 0) - before.fetch(:time, 0)).fdiv(1000 * count),
      gc_before: before,
      gc_after: after,
      minor_gc_count: after[:minor_gc_count] - before[:minor_gc_count],
      major_gc_count: after[:major_gc_count] - before[:major_gc_count],
      allocations: (after[:total_allocated_objects] - before[:total_allocated_objects]).fdiv(count),
      gc_count: after[:count] - before[:count],
      count: count,
    }
  end
  host_metrics = BenchmarkHostMetrics.finish(observer, samples)
  times = samples.map { |sample| sample.fetch(:seconds) }.sort
  rss = File.read("/proc/self/status")[/^VmHWM:\s+(\d+)/, 1]&.to_i if File.exist?("/proc/self/status")
  {
    median_seconds: times[times.size / 2],
    host_metrics: host_metrics,
    min_seconds: times.first,
    max_seconds: times.last,
    spread: (times.last - times.first) / times[times.size / 2],
    allocations: samples.sum { |sample| sample.fetch(:allocations) } / samples.size,
    peak_rss_kb: rss,
    samples: samples,
  }
ensure
  BenchmarkHostMetrics.stop(observer)
end
