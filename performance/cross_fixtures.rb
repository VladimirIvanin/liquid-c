# frozen_string_literal: true

require_relative "cross_engine"

class BenchmarkFileSystem
  def initialize(partials)
    @partials = partials
  end

  def read_template_file(name, *)
    @partials.fetch(name)
  end
end

mode = ARGV.shift || "warn"
configure_error_mode(mode.to_sym)
require_relative "workloads"
fixtures = benchmark_fixtures
fixtures.select! { |fixture| ARGV.empty? || ARGV.any? { |pattern| fixture.fetch("id").include?(pattern) } }
abort "no matching fixtures" if fixtures.empty?
fixtures.each do |fixture|
  filesystem = BenchmarkFileSystem.new(fixture.fetch("partials"))
  options = { error_mode: mode.to_sym, line_numbers: true }
  if LIQUID5
    options[:environment] = Liquid::Environment.build(error_mode: mode.to_sym) do |environment|
      environment.file_system = filesystem
    end
  end
  parse = -> { Liquid::Template.parse(fixture.fetch("source"), **options) }
  render = ->(template) {
    template.render!(
      fixture.fetch("assigns"),
      registers: { file_system: filesystem, cached_partials: {}, cycle: {}, for: {} },
    )
  }
  prepared = parse.call
  output = render.call(prepared)
  raise "incorrect output: #{fixture.fetch("id")}" unless output == fixture.fetch("expected")

  metadata = engine_info.merge(
    scenario: fixture.fetch("id"),
    error_mode: mode,
    line_numbers: true,
    output_sha256: Digest::SHA256.hexdigest(output),
    corpus_sha256: Digest::SHA256.hexdigest(JSON.generate(fixture, max_nesting: false)),
  )
  if ENV["CHECK_ONLY"] == "1"
    raise "unstable fixture output" unless render.call(prepared) == output

    puts JSON.generate(metadata.merge(mode: "verify", verified: true))
    next
  end

  operations = {
    "parse" => parse,
    "render" => -> { render.call(prepared) },
    "parse_render" => -> {
                        render.call(parse.call)
                      },
  }
  phases = ENV.fetch("PHASES", "parse,render,parse_render").split(",")
  phases.each do |phase|
    measurements = measure(
      operations.fetch(phase),
      warmup: Float(ENV.fetch("WARMUP", "2")),
      batch: Float(ENV.fetch("BATCH_SECONDS", "1")),
      repeats: Integer(ENV.fetch("REPEATS", "7")),
    )
    raise "output changed during measurement" unless render.call(prepared) == output

    puts JSON.generate(metadata.merge(mode: phase).merge(measurements))
    $stdout.flush
  end
end
