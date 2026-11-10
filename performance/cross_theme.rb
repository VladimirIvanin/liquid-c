# frozen_string_literal: true

require_relative "cross_engine"

PERF = File.join(__dir__, "theme")
helpers = File.join(PERF, LIQUID5 ? "shopify5" : "shopify4")
["comment_form", "paginate", "json_filter", "money_filter", "shop_filter", "tag_filter", "weight_filter"].each do |f|
  require File.join(helpers, f)
end
require File.join(PERF, "database")

if LIQUID5
  env = Liquid::Environment.default
  env.register_tag("paginate", Paginate)
  env.register_tag("form", CommentForm)
  [JsonFilter, MoneyFilter, WeightFilter, ShopFilter, TagFilter].each { |m| env.register_filter(m) }
else
  Liquid::Template.register_tag("paginate", Paginate)
  Liquid::Template.register_tag("form", CommentForm)
  [JsonFilter, MoneyFilter, WeightFilter, ShopFilter, TagFilter].each { |m| Liquid::Template.register_filter(m) }
end

mode_name = (ARGV.first || "lax").to_s
error_mode = mode_name.to_sym
LINE_NUMBERS = mode_name == "warn"
configure_error_mode(error_mode)
PARSE_OPTIONS = LINE_NUMBERS ? { line_numbers: true }.freeze : {}.freeze

class ThemeRunner
  class FileSystem
    def initialize(path)
      @path = path
    end

    def read_template_file(template_path, *)
      File.read(@path + "/" + template_path + ".liquid")
    end
  end

  attr_reader :tests

  def initialize
    @tests = Dir[PERF + "/tests/**/*.liquid"].sort.collect do |test|
      next if File.basename(test) == "theme.liquid"

      theme_path = File.dirname(test) + "/theme.liquid"
      {
        liquid: File.read(test),
        layout: (File.file?(theme_path) ? File.read(theme_path) : nil),
        template_name: test,
      }
    end.compact
    compile_all_tests
  end

  def compile
    @tests.each do |test_hash|
      Liquid::Template.new.parse(test_hash[:liquid], PARSE_OPTIONS)
      Liquid::Template.new.parse(test_hash[:layout], PARSE_OPTIONS)
    end
  end

  def run
    each_test do |liquid, layout, assigns, page_template, template_name|
      compiled = compile_test(liquid, layout, assigns, page_template, template_name)
      assigns["content_for_layout"] =
        compiled[:tmpl].render!(assigns, registers: { cycle: {}, for: {}, cached_partials: {} })
      compiled[:layout]&.render!(assigns, registers: { cycle: {}, for: {}, cached_partials: {} })
    end
  end

  def render
    @compiled_tests.each do |test|
      tmpl = test[:tmpl]
      assigns = test[:assigns]
      layout = test[:layout]
      if layout
        assigns["content_for_layout"] = tmpl.render!(assigns, registers: { cycle: {}, for: {}, cached_partials: {} })
        layout.render!(assigns, registers: { cycle: {}, for: {}, cached_partials: {} })
      else
        tmpl.render!(assigns, registers: { cycle: {}, for: {}, cached_partials: {} })
      end
    end
  end

  # Collected outputs of every page (+layout) for cross-engine comparison.
  def outputs
    @compiled_tests.map.with_index do |test, i|
      assigns = test[:assigns]
      body = test[:tmpl].render!(assigns, registers: { cycle: {}, for: {}, cached_partials: {} })
      full = if test[:layout]
        assigns["content_for_layout"] = body
        test[:layout].render!(assigns, registers: { cycle: {}, for: {}, cached_partials: {} })
      else
        body
      end
      [@tests[i][:template_name].sub(PERF + "/", ""), full]
    end
  end

  private

  def compile_all_tests
    @compiled_tests = []
    each_test do |liquid, layout, assigns, page_template, template_name|
      @compiled_tests << compile_test(liquid, layout, assigns, page_template, template_name)
    end
  end

  def compile_test(template, layout, assigns, page_template, template_file)
    tmpl = init_template(page_template, template_file)
    parsed_template = tmpl.parse(template, PARSE_OPTIONS).dup
    if layout
      { tmpl: parsed_template, assigns: assigns, layout: tmpl.parse(layout, PARSE_OPTIONS) }
    else
      { tmpl: parsed_template, assigns: assigns }
    end
  end

  def each_test
    assigns = Database.tables.dup
    @tests.each do |test_hash|
      page_template = File.basename(test_hash[:template_name], File.extname(test_hash[:template_name]))
      yield(test_hash[:liquid], test_hash[:layout], assigns, page_template, test_hash[:template_name])
    end
  end

  def init_template(page_template, template_file)
    tmpl = Liquid::Template.new
    tmpl.assigns["page_title"] = "Page title"
    tmpl.assigns["template"] = page_template
    tmpl.registers[:file_system] = ThemeRunner::FileSystem.new(File.dirname(template_file))
    tmpl
  end
end

corpus = ENV.fetch("THEME_CORPUS", "original")
abort "THEME_CORPUS must be original, fleur or all" unless ["original", "fleur", "all"].include?(corpus)
check_only = ENV["CHECK_ONLY"] == "1"
runner = ThemeRunner.new unless corpus == "fleur"
if ENV["PROFILE"]
  abort "PROFILE currently supports only THEME_CORPUS=original" unless corpus == "original"
  require "stackprof"
  deadline = CLOCK.call + Float(ENV.fetch("PROFILE_SECONDS", "5"))
  StackProf.run(mode: :cpu, out: ENV.fetch("PROFILE"), interval: 100) do
    runner.compile while CLOCK.call < deadline
  end
  exit
end
out_dir = ENV.fetch("OUT_DIR")
tag = "#{BENCH_CONFIGURATION.fetch("name")}-#{error_mode}"
repeats = Integer(ENV.fetch("REPEATS", "7"))
batch = Float(ENV.fetch("BATCH_SECONDS", "1.0"))
warmup = Float(ENV.fetch("WARMUP", "2.0"))
abort "invalid measurement settings" unless repeats.positive? && batch.positive? && warmup >= 0
common = engine_info.merge(
  error_mode: error_mode,
  line_numbers: LINE_NUMBERS,
  corpus_sha256: Digest::SHA256.hexdigest(Dir[PERF + "/**/*"].select { |path| File.file?(path) }.sort.map do |path|
                                            path.delete_prefix(PERF) + "\0" + File.binread(path)
                                          end.join("\0")),
)

if runner
  outputs = runner.outputs
  File.write(File.join(out_dir, "theme-outputs-#{tag}.json"), JSON.pretty_generate(outputs.to_h))
  metadata = common.merge(
    scenario: "theme",
    templates: runner.tests.size,
    output_sha256: Digest::SHA256.hexdigest(outputs.flatten.join("\0")),
  )
  if check_only
    raise "unstable original theme output" unless runner.outputs == outputs

    puts JSON.generate(metadata.merge(mode: "verify", verified: true))
  else
    phases = ENV.fetch("PHASES", "parse,render,run").split(",")
    ops = { "parse" => -> { runner.compile }, "render" => -> { runner.render }, "run" => -> { runner.run } }
    phases.each do |phase|
      before = runner.outputs
      r = measure(ops.fetch(phase), warmup: warmup, batch: batch, repeats: repeats)
      raise "output changed during measurement" unless runner.outputs == before

      puts JSON.generate(metadata.merge(mode: phase == "run" ? "parse_render" : phase).merge(r))
      $stdout.flush
    end
  end
end

unless corpus == "original"
  require_relative "theme/fleur_runner"
  data_modes = ENV.fetch("FLEUR_DATA", "hash,drop").split(",")
  abort "FLEUR_DATA must contain hash and/or drop" if data_modes.empty? || (data_modes - ["hash", "drop"]).any?
  patterns = ARGV.drop(1)
  fixtures = FleurThemeRunner.fixtures.select do |fixture|
    patterns.empty? || patterns.any? { |pattern| fixture.fetch(:name).include?(pattern) }
  end
  abort "no Fleur scenarios selected" if fixtures.empty?
  fleur_outputs = {}
  fixtures.each do |fixture|
    data_modes.uniq.each do |data_mode|
      fleur = FleurThemeRunner.new(fixture, data_mode: data_mode, parse_options: PARSE_OPTIONS)
      html = fleur.verify!
      fleur_outputs[fleur.name] = html
      metadata = common.merge(fleur.metadata).merge(output_sha256: Digest::SHA256.hexdigest(html))
      if check_only
        puts JSON.generate(metadata.merge(mode: "verify", verified: true))
        next
      end
      ops = {
        "parse" => -> { fleur.compile },
        "parse_all" => -> { fleur.compile_all },
        "render" => -> { fleur.render },
        "render_warm_partials" => -> { fleur.render_warm_partials },
        "run" => -> { fleur.run },
      }
      phases = ENV.fetch("PHASES", "parse,parse_all,render,render_warm_partials,run").split(",")
      phases.each do |phase|
        result = measure(ops.fetch(phase), warmup: warmup, batch: batch, repeats: repeats)
        fleur.verify!
        parse_scope = if phase == "parse_all"
          "root and every declared partial once; independent parse contexts"
        else
          "root only; includes load during render"
        end
        partial_cache = if phase.start_with?("parse")
          "not used"
        elsif phase == "render_warm_partials"
          "compiled partials reused; fresh request registers"
        else
          "fresh per render; includes parse inside timing"
        end
        puts JSON.generate(metadata.merge(
          mode: phase == "run" ? "parse_render" : phase,
          parse_scope: parse_scope,
          partial_cache: partial_cache,
        ).merge(result))
        $stdout.flush
      end
    end
  end
  File.write(File.join(out_dir, "fleur-outputs-#{tag}.json"), JSON.pretty_generate(fleur_outputs))
end
