# frozen_string_literal: true

require "json"
require "rbconfig"
require "fileutils"
require "open3"

abort "usage: cross_compare.rb ENGINES.json OUTPUT [theme|fixtures] [patterns...]" if ARGV.size < 2
configurations = JSON.parse(File.read(ARGV.fetch(0)))
names = configurations.map { |configuration| configuration.fetch("name") }
abort "engine names must be unique and nonempty" if names.empty? || names.uniq.size != names.size
output = File.expand_path(ARGV.fetch(1))
workload = ARGV.fetch(2, "theme")
abort "unknown workload" unless ["theme", "fixtures"].include?(workload)
FileUtils.mkdir_p(output)
harness = File.join(output, "harness")
abort "measurement harness already exists: #{harness}; use a new output directory" if File.exist?(harness)
FileUtils.mkdir_p(harness)
[
  "cross_compare.rb",
  "cross_engine.rb",
  "cross_theme.rb",
  "cross_fixtures.rb",
  "host_metrics.rb",
  "workloads.rb",
  "fixtures.json",
].each { |file| FileUtils.cp(File.join(__dir__, file), harness) }
FileUtils.cp_r(File.join(__dir__, "theme"), harness)
configurations.reverse! if ENV["REVERSE_ORDER"] == "true"
records = []
configurations.each do |configuration|
  name = configuration.fetch("name")
  abort "invalid engine name" unless /\A[\w-]+\z/.match?(name)
  env = {
    "BENCH_CONFIGURATION" => JSON.generate(configuration),
    "OUT_DIR" => output,
    "RUBYOPT" => nil,
    "BUNDLE_GEMFILE" => nil,
    "RUBYLIB" => nil,
    "GEM_PATH" => configuration["gem_path"] || ENV["GEM_PATH"],
  }
  script = File.join(harness, workload == "theme" ? "cross_theme.rb" : "cross_fixtures.rb")
  command = [RbConfig.ruby, "--disable-yjit", script, ENV.fetch("ERROR_MODE", "warn"), *ARGV.drop(3)]
  path = File.join(output, "#{name}.jsonl")
  File.open(path, "w") do |file|
    abort "#{name} failed" unless system(env, *command, out: file)
  end
  rows = File.readlines(path).map { |line| JSON.parse(line) }
  abort "#{name}: no measurements" if rows.empty?
  records.concat(rows)
  if workload == "theme"
    descriptions = rows.map do |row|
      if row["verified"]
        "#{row.fetch("scenario")}: verified"
      else
        "#{row.fetch("scenario")}/#{row.fetch("mode")}=#{(row.fetch("median_seconds") * 1000).round(3)}ms"
      end
    end
    puts "#{name}: #{descriptions.join(", ")}"
  else
    puts "#{name}: #{rows.size} measurements"
  end
  unstable = rows.count { |row| row.fetch("spread", 0) > 0.05 }
  puts "#{name}: #{unstable} measurements exceed 5% spread; repeat before drawing conclusions" if unstable.positive?
  $stdout.flush
end
records.group_by { |row| [row.fetch("scenario"), row.fetch("mode")] }.each do |key, rows|
  abort "missing or duplicate engine result: #{key.inspect}" unless rows.map do |row|
                                                                      row.fetch("variant")
                                                                    end.sort == names.sort
  abort "measurement harness changed: #{key.inspect}" unless rows.map do |row|
                                                               row.fetch("harness_sha256")
                                                             end.uniq.size == 1
  abort "output mismatch: #{key.inspect}" unless rows.map { |row| row.fetch("output_sha256") }.uniq.size == 1
  abort "corpus mismatch: #{key.inspect}" unless rows.map { |row| row.fetch("corpus_sha256") }.uniq.size == 1
end
File.write(File.join(output, "run.json"), JSON.pretty_generate(
  configurations: configurations,
  ruby: RUBY_DESCRIPTION,
  workload: workload,
  repeats: ENV.fetch("REPEATS", "7"),
  warmup: ENV.fetch("WARMUP", "2"),
  batch_seconds: ENV.fetch("BATCH_SECONDS", "1"),
  theme_corpus: ENV.fetch("THEME_CORPUS", "original"),
  fleur_data: ENV.fetch("FLEUR_DATA", "hash,drop"),
  check_only: ENV["CHECK_ONLY"] == "1",
  phases: ENV["PHASES"],
  patterns: ARGV.drop(3),
) + "\n")
