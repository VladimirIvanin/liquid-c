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
fixtures = JSON.parse(File.read(File.join(__dir__, "fixtures.json"))).fetch("scenarios")
fixtures.push(
  { "id" => "text/small", "source" => "plain " * 80, "assigns" => {}, "partials" => {}, "expected" => "plain " * 80 },
  {
    "id" => "text/large",
    "source" => "plain " * 20_000,
    "assigns" => {},
    "partials" => {},
    "expected" => "plain " * 20_000,
  },
  {
    "id" => "unique/large",
    "source" => (0...384).map { |i| "{{ value#{i} }}" }.join,
    "assigns" => (0...384).to_h { |i| ["value#{i}", i] },
    "partials" => {},
    "expected" => (0...384).to_a.join,
  },
  {
    "id" => "condition_headers/large",
    "source" => "{% if value > 1 and value < 4 %}x{% endif %}" * 96,
    "assigns" => { "value" => 2 },
    "partials" => {},
    "expected" => "x" * 96,
  },
  {
    "id" => "for_headers/large",
    "source" => "{% for i in values reversed limit: 1 %}{{ i }}{% endfor %}" * 96,
    "assigns" => { "values" => [1, 2, 3] },
    "partials" => {},
    "expected" => "1" * 96,
  },
  {
    "id" => "case_headers/large",
    "source" => "{% case value %}{% when 2 %}x{% else %}y{% endcase %}" * 96,
    "assigns" => { "value" => 2 },
    "partials" => {},
    "expected" => "x" * 96,
  },
)
case_assigns = (0...96).to_h do |index|
  value = { "value" => 2 }
  40.times { value = { "child" => value } }
  ["product#{index}", value]
end
fixtures << {
  "id" => "case_deep/large",
  "source" => (0...96).map do |index|
    "{% case product#{index}#{".child" * 40}.value %}{% when 2 %}x{% else %}y{% endcase %}"
  end.join,
  "assigns" => case_assigns,
  "partials" => {},
  "expected" => "x" * 96,
}
condition_assigns = (0...96).to_h do |index|
  value = { "value" => 2 }
  40.times { value = { "child" => value } }
  ["product#{index}", value]
end
fixtures << {
  "id" => "condition_deep/large",
  "source" => (0...96).map do |index|
    "{% if product#{index}#{".child" * 40}.value == 2 %}x{% endif %}"
  end.join,
  "assigns" => condition_assigns,
  "partials" => {},
  "expected" => "x" * 96,
}
for_assigns = (0...96).to_h do |index|
  value = { "values" => [1] }
  40.times { value = { "child" => value } }
  ["product#{index}", value]
end
fixtures << {
  "id" => "for_deep/large",
  "source" => (0...96).map do |index|
    "{% for i in product#{index}#{".child" * 40}.values %}{{ i }}{% endfor %}"
  end.join,
  "assigns" => for_assigns,
  "partials" => {},
  "expected" => "1" * 96,
}
deep_assigns = (0...16).to_h do |index|
  value = "ok"
  256.times { value = { "child" => value } }
  ["product#{index}", value]
end
fixtures << {
  "id" => "expression_deep/large",
  "source" => (0...16).map { |index| "{{ product#{index}#{".child" * 256} }}" }.join,
  "assigns" => deep_assigns,
  "partials" => {},
  "expected" => "ok" * 16,
}
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
