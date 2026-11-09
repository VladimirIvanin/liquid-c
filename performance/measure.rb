# frozen_string_literal: true

require "bundler/setup"
require "json"
require "digest"
require "strscan"
$LOAD_PATH.unshift(ENV["LIQUID_C_EXTENSION_DIR"]) if ENV["LIQUID_C_EXTENSION_DIR"]
$LOAD_PATH.unshift(ENV["LIQUID_C_LIBRARY_DIR"]) if ENV["LIQUID_C_LIBRARY_DIR"]
require "liquid"
require "liquid/c" unless ENV["BENCH_ENGINE"] == "pure"

class BenchmarkFileSystem
  def initialize(partials)
    @partials = partials
  end

  def read_template_file(name, *)
    @partials.fetch(name)
  end
end

if ENV["EDITOR_PATCH"] == "true"
  Liquid::Variable.prepend(Module.new do
    def render(context)
      context.registers[:variable_markup] = @markup
      super
    end
  end)
end

clock = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
require_relative "workloads"
fixtures = benchmark_fixtures
if ARGV.delete("--list")
  puts JSON.generate(fixtures.map { |fixture| fixture.fetch("id") })
  exit
end
fixtures.select! { |fixture| ARGV.empty? || ARGV.any? { |pattern| fixture.fetch("id").include?(pattern) } }
fixtures.each do |fixture|
  environment = Liquid::Environment.build(error_mode: :strict) do |env|
    env.file_system = BenchmarkFileSystem.new(fixture.fetch("partials"))
  end
  parse = -> { Liquid::Template.parse(fixture.fetch("source"), environment: environment) }
  render = ->(template) { template.render!(fixture.fetch("assigns"), registers: { cached_partials: {} }) }
  stats = {}
  Liquid::Template.parse(fixture.fetch("source"), environment: environment, native_parser_stats: stats)
  prepared = parse.call
  raise "incorrect output: #{fixture.fetch("id")}" unless render.call(prepared) == fixture.fetch("expected")

  {
    parse: parse,
    render: -> { render.call(prepared) },
    parse_render: -> {
                    render.call(parse.call)
                  },
  }.each do |mode, operation|
    deadline = clock.call + 0.15
    operation.call while clock.call < deadline
    samples = Array.new(Integer(ENV.fetch("REPEATS", "5"))) do
      GC.start
      before = GC.stat(:total_allocated_objects)
      count = 0
      started = clock.call
      deadline = started + Float(ENV.fetch("BATCH_SECONDS", "0.3"))
      loop do
        operation.call
        count += 1
        break if clock.call >= deadline
      end
      elapsed = clock.call - started
      { seconds: elapsed / count, allocations: (GC.stat(:total_allocated_objects) - before).fdiv(count) }
    end
    observed = mode == :parse ? render.call(operation.call) : operation.call
    raise "incorrect measured output: #{fixture.fetch("id")}/#{mode}" unless observed == fixture.fetch("expected")

    times = samples.map { |sample| sample.fetch(:seconds) }.sort
    rss = File.read("/proc/self/status")[/^VmHWM:\s+(\d+)/, 1]&.to_i if File.exist?("/proc/self/status")
    puts JSON.generate(
      scenario: fixture.fetch("id"),
      mode: mode,
      native_stats: stats,
      ruby: RUBY_DESCRIPTION,
      yjit: defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?,
      liquid: Liquid::VERSION,
      extension: $LOADED_FEATURES.find { |path| path.end_with?("/liquid_c.so") },
      opaque_method_guards: defined?(Liquid::C::NativeParser) && Liquid::C::NativeParser::NATIVE_GUARDS,
      native_parser: ENV["LIQUID_C_NATIVE_PARSER"] != "false",
      variant: ENV.fetch("BENCH_VARIANT", "current"),
      median_seconds: times[times.size / 2],
      min_seconds: times.first,
      max_seconds: times.last,
      allocations: samples.sum { |sample| sample.fetch(:allocations) } / samples.size,
      peak_rss_kb: rss,
      output_sha256: Digest::SHA256.hexdigest(fixture.fetch("expected")),
      samples: samples,
    )
  end
end
