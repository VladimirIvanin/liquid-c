# frozen_string_literal: true

# Corpus-inspired synthetic comparison. The bench_* extensions below are identical
# demonstration implementations in both engines.
# CHECK_ONLY=1 ruby performance/fleur_synthetic.rb ENGINES.json OUTPUT [pattern...]
# taskset -c CORE ruby performance/fleur_synthetic.rb ENGINES.json OUTPUT [pattern...]
# Optional: PHASES=parse,render_first,render,parse_render ROUNDS=2 REPEATS=7
# WARMUP=2 BATCH_SECONDS=1 FIRST_RENDER_BATCH=64 EXPRESSION_CACHE=default|off

require "json"
require "digest"
require "rbconfig"
require "fileutils"

unless ARGV.first == "--engine"
  abort "usage: #{$PROGRAM_NAME} ENGINES.json OUTPUT [patterns...]" if ARGV.length < 2
  configurations = JSON.parse(File.read(ARGV.shift))
  output = File.expand_path(ARGV.shift)
  patterns = ARGV.dup
  FileUtils.mkdir_p(output)
  # Freeze the measurement code too: another worker may edit cross_engine.rb
  # while a long comparison is running. Children all use this identical copy.
  harness = File.join(output, "harness")
  FileUtils.mkdir_p(harness)
  [
    "fleur_synthetic.rb",
    "fleur_synthetic_workloads.rb",
    "cross_engine.rb",
    "host_metrics.rb",
    "cross_compare.rb",
    "cross_theme.rb",
    "cross_fixtures.rb",
    "workloads.rb",
    "fixtures.json",
  ].each do |name|
    File.binwrite(File.join(harness, name), File.binread(File.join(__dir__, name)))
  end
  rounds = ENV["CHECK_ONLY"] == "1" ? 1 : Integer(ENV.fetch("ROUNDS", "2"))
  abort "ROUNDS must be positive" unless rounds.positive?
  records = []
  fingerprints = {}
  rounds.times do |round|
    order = round.even? ? configurations : configurations.reverse
    order.each do |configuration|
      name = configuration.fetch("name")
      abort "invalid engine name" unless /\A[\w-]+\z/.match?(name)
      env = {
        "BENCH_CONFIGURATION" => JSON.generate(configuration),
        "RUBYOPT" => nil,
        "RUBYLIB" => nil,
        "BUNDLE_GEMFILE" => nil,
        "GEM_PATH" => configuration["gem_path"] || ENV["GEM_PATH"],
        "OUT_DIR" => output,
      }
      path = File.join(output, "round-#{round + 1}-#{name}.jsonl")
      command = [RbConfig.ruby, "--disable-yjit", File.join(harness, "fleur_synthetic.rb"), "--engine", *patterns]
      File.open(path, "w") do |file|
        abort "#{name} failed; inspect #{path}" unless system(env, *command, out: file)
      end
      rows = File.readlines(path).map { |line| JSON.parse(line) }
      abort "no records for #{name}" if rows.empty?
      rows.each do |row|
        fingerprint = row.values_at("extension_sha256", "library_sha256", "liquid_source_sha256")
        if fingerprints.key?(name) && fingerprints[name] != fingerprint
          abort "#{name} changed during the series; repeat on fixed builds"
        end
        fingerprints[name] = fingerprint
        records << row.merge("round" => round + 1)
      end
      puts "round #{round + 1}: #{name}, #{rows.size} records, HTML verified"
      $stdout.flush
    end
  end
  groups = records.group_by { |row| row.values_at("scenario", "mode") }
  groups.each do |key, rows|
    ["output_sha256", "corpus_sha256", "harness_sha256", "expression_cache"].each do |field|
      abort "#{field} mismatch: #{key.inspect}" unless rows.map { |row| row.fetch(field) }.uniq.size == 1
    end
    abort "missing engine: #{key.inspect}" unless rows.map do |row|
                                                    row.fetch("variant")
                                                  end.uniq.sort == configurations.map do |c|
                                                                     c.fetch("name")
                                                                   end.uniq.sort
  end
  summary = groups.map do |(scenario, phase), rows|
    engines = rows.group_by { |row| row.fetch("variant") }.transform_values do |engine_rows|
      samples = engine_rows.flat_map { |row| row.fetch("samples", []) }
      next { "verified" => true } if samples.empty?

      times = samples.map { |sample| sample.fetch("seconds") }.sort
      median = times[times.size / 2]
      {
        "median_ms" => median * 1000,
        "spread" => (times.last - times.first) / median,
        "allocations_per_op" => samples.sum { |sample| sample.fetch("allocations") } / samples.size,
      }
    end
    item = { "scenario" => scenario, "mode" => phase, "engines" => engines }
    if engines.dig("current", "median_ms") && engines.dig("legacy", "median_ms")
      item["current_over_legacy"] = engines["current"]["median_ms"] / engines["legacy"]["median_ms"]
    end
    item
  end
  File.write(File.join(output, "summary.json"), JSON.pretty_generate(summary) + "\n")
  File.write(File.join(output, "run.json"), JSON.pretty_generate(
    configurations: configurations,
    rounds: rounds,
    ruby: RUBY_DESCRIPTION,
    parameters: ENV.select { |k, _|
                  [
                    "CHECK_ONLY",
                    "PHASES",
                    "ROUNDS",
                    "REPEATS",
                    "WARMUP",
                    "BATCH_SECONDS",
                    "FIRST_RENDER_BATCH",
                    "EXPRESSION_CACHE",
                  ].include?(k)
                },
    note: "Synthetic extensions; no aggregate score without traffic weights.",
  ) + "\n")
  exit
end

ARGV.shift
require_relative "cross_engine"
require_relative "fleur_synthetic_workloads"
abort "use Ruby 3.2 for the agreed comparison" unless RUBY_VERSION.start_with?("3.2.")
configure_error_mode(:warn)
cache_mode = ENV.fetch("EXPRESSION_CACHE", "default")
abort "EXPRESSION_CACHE must be default or off" unless ["default", "off"].include?(cache_mode)

module SyntheticWidgetFilters
  def bench_money(input)
    format("%.2f", input.to_f / 100)
  end

  def bench_image_url(input, width, options = {})
    "/img/#{input}?w=#{width}&format=#{options.fetch("format", "original")}&quality=#{options.fetch("quality", 80)}"
  end
end

class SyntheticWidgetMarker < Liquid::Tag
  def initialize(name, markup, context)
    super
    @key = markup.strip
  end

  def render(context)
    "<b>#{context[@key]}</b>"
  end
end

class SyntheticWidgetCache < Liquid::Block
  def initialize(name, markup, context)
    super
    @key = markup.strip.delete_prefix("'").delete_suffix("'")
  end

  def render(context)
    store = context.registers[:bench_fragment_cache]
    return store[@key] if store.key?(@key)

    store[@key] = super(context)
  end
end

class SyntheticWidgetFileSystem
  def initialize(partials)
    @partials = partials
  end

  def read_template_file(name, *)
    @partials.fetch(name)
  end
end

unless LIQUID5
  Liquid::Template.register_filter(SyntheticWidgetFilters)
  Liquid::Template.register_tag("bench_marker", SyntheticWidgetMarker)
  Liquid::Template.register_tag("bench_cache", SyntheticWidgetCache)
end

def source_digest(directory)
  digest = Digest::SHA256.new
  Dir[File.join(directory, "**", "*.rb")].sort.each do |path|
    digest << path.delete_prefix(directory) << "\0" << File.binread(path) << "\0"
  end
  digest.hexdigest
end

def widget_sample(count, before, elapsed)
  after = GC.stat
  {
    seconds: elapsed / count,
    count: count,
    allocations: (after[:total_allocated_objects] - before[:total_allocated_objects]).fdiv(count),
    gc_per_op: (after[:count] - before[:count]).fdiv(count),
    minor_gc_per_op: (after[:minor_gc_count] - before[:minor_gc_count]).fdiv(count),
    major_gc_per_op: (after[:major_gc_count] - before[:major_gc_count]).fdiv(count),
  }
end

def measure_widget(phase, parse, render, expected, warmup:, batch:, repeats:, first_batch:)
  prepared = parse.call
  raise "incorrect independent verification" unless render.call(prepared) == expected

  operation = case phase
  when "parse" then parse
  when "render" then -> { render.call(prepared) }
  when "parse_render", "render_first" then -> { render.call(parse.call) }
  else raise "unknown phase #{phase}"
  end
  if phase != "render_first"
    last = nil
    measurements = measure(-> { last = operation.call }, warmup: warmup, batch: batch, repeats: repeats)
    raise "output changed during #{phase}" if phase != "parse" && last != expected

    measurements[:samples].each do |sample|
      sample[:gc_per_op] = sample.fetch(:gc_count).fdiv(sample.fetch(:count))
      sample[:minor_gc_per_op] = sample.fetch(:minor_gc_count).fdiv(sample.fetch(:count))
      sample[:major_gc_per_op] = sample.fetch(:major_gc_count).fdiv(sample.fetch(:count))
    end
    return measurements.merge(first_render_batch: nil)
  end
  deadline = CLOCK.call + warmup
  operation.call while CLOCK.call < deadline
  samples = Array.new(repeats) do
    last = nil
    if phase == "render_first"
      # These objects have NEVER been rendered. Compilation is outside timing.
      templates = Array.new(first_batch) { parse.call }
      GC.start
      before = GC.stat
      started = CLOCK.call
      templates.each { |template| last = render.call(template) }
      elapsed = CLOCK.call - started
      sample = widget_sample(first_batch, before, elapsed)
      templates = nil # rubocop:disable Lint/UselessAssignment -- release the batch before the next iteration
    else
      GC.start
      before = GC.stat
      count = 0
      started = CLOCK.call
      deadline = started + batch
      loop do
        last = operation.call
        count += 1
        break if CLOCK.call >= deadline
      end
      sample = widget_sample(count, before, CLOCK.call - started)
    end
    raise "output changed during #{phase}" if phase != "parse" && last != expected

    sample
  end
  times = samples.map { |sample| sample.fetch(:seconds) }.sort
  {
    median_seconds: times[times.size / 2],
    spread: (times.last - times.first) / times[times.size / 2],
    samples: samples,
    first_render_batch: phase == "render_first" ? first_batch : nil,
  }
end

fixtures = SyntheticWidgetWorkloads.build.select do |fixture|
  ARGV.empty? || ARGV.any? { |pattern| fixture.fetch("id").include?(pattern) }
end
abort "no matching scenarios" if fixtures.empty?
info = engine_info.merge(
  library_sha256: BENCH_CONFIGURATION["library"] && source_digest(BENCH_CONFIGURATION.fetch("library")),
  liquid_source_sha256: source_digest(File.join(BENCH_CONFIGURATION.fetch("liquid_root"), "lib")),
  harness_sha256: Digest::SHA256.hexdigest(
    ["fleur_synthetic.rb", "fleur_synthetic_workloads.rb", "cross_engine.rb", "host_metrics.rb"].map do |name|
      name + "\0" + File.binread(File.join(__dir__, name))
    end.join("\0"),
  ),
  native_switches: ENV.select { |k, _| k.start_with?("LIQUID_C_NATIVE_") },
)
phases = ENV.fetch("PHASES", "parse,render_first,render,parse_render").split(",")
repeats = Integer(ENV.fetch("REPEATS", "7"))
batch = Float(ENV.fetch("BATCH_SECONDS", "1"))
warmup = Float(ENV.fetch("WARMUP", "2"))
first_batch = Integer(ENV.fetch("FIRST_RENDER_BATCH", "64"))
abort "invalid measurement settings" unless repeats.positive? && batch.positive? && warmup >= 0 && first_batch.positive?
fixtures.each do |fixture|
  before_fixture = JSON.generate(fixture)
  filesystem = SyntheticWidgetFileSystem.new(fixture.fetch("partials"))
  options = { error_mode: :warn, line_numbers: true }
  options[:expression_cache] = false if cache_mode == "off"
  if LIQUID5
    options[:environment] = Liquid::Environment.build(error_mode: :warn) do |environment|
      environment.file_system = filesystem
      environment.register_filter(SyntheticWidgetFilters)
      environment.register_tag("bench_marker", SyntheticWidgetMarker)
      environment.register_tag("bench_cache", SyntheticWidgetCache)
    end
  end
  parse = -> { Liquid::Template.parse(fixture.fetch("source"), **options) }
  render = ->(template) do
    # A new request state each time; no accidental cross-iteration fragment hits.
    fragments = fixture.fetch("cache_mode") == "hit" ? { "card-grid" => fixture.fetch("expected").dup } : {}
    template.render!(fixture.fetch("assigns"), registers: {
      file_system: filesystem, cached_partials: {}, cycle: {}, for: {}, bench_fragment_cache: fragments,
    })
  end
  base = info.merge(
    scenario: fixture.fetch("id"),
    error_mode: "warn",
    line_numbers: true,
    expression_cache: cache_mode,
    fragment_cache: fixture.fetch("cache_mode"),
    partial_cache: "fresh per render; include compilation remains inside render",
    data_model: "plain Hash/Array; application Drops are not simulated",
    corpus_sha256: Digest::SHA256.hexdigest(before_fixture),
    output_sha256: Digest::SHA256.hexdigest(fixture.fetch("expected")),
    output_bytes: fixture.fetch("expected").bytesize,
    source_bytes: fixture.fetch("source").bytesize,
  )
  if ENV["CHECK_ONLY"] == "1"
    template = parse.call
    2.times do
      raise "incorrect output: #{fixture.fetch("id")}" unless render.call(template) == fixture.fetch("expected")
    end
    raise "incorrect fresh output" unless render.call(parse.call) == fixture.fetch("expected")

    puts JSON.generate(base.merge(mode: "check", verified: true))
  else
    phases.each do |phase|
      result = measure_widget(
        phase,
        parse,
        render,
        fixture.fetch("expected"),
        warmup: warmup,
        batch: batch,
        repeats: repeats,
        first_batch: first_batch,
      )
      puts JSON.generate(base.merge(mode: phase).merge(result))
      $stdout.flush
    end
  end
  raise "fixture was mutated: #{fixture.fetch("id")}" unless JSON.generate(fixture) == before_fixture
end
