# frozen_string_literal: true

require "json"
require "rbconfig"
require "open3"
require "fileutils"

abort "usage: run_comparison.rb BASE_EXTENSION BASE_LIBRARY CURRENT_EXTENSION OUTPUT" unless ARGV.size == 4

base_extension, base_library, current_extension, output = ARGV.map { |path| File.expand_path(path) }
abort "baseline library contains a different extension" unless Dir[File.join(
  base_library,
  "liquid_c.{so,bundle,dll}",
)].empty?

variants = {
  "baseline" => {
    "LIQUID_C_EXTENSION_DIR" => base_extension,
    "LIQUID_C_LIBRARY_DIR" => base_library,
    "BENCH_VARIANT" => "baseline",
  },
  "current" => {
    "LIQUID_C_EXTENSION_DIR" => current_extension,
    "LIQUID_C_LIBRARY_DIR" => nil,
    "BENCH_VARIANT" => "current",
  },
}
command = [RbConfig.ruby]
command << "--yjit" if ENV["BENCH_YJIT"] == "true"
command.push("-Ilib", "performance/measure.rb")
list, error, status = Open3.capture3(variants.fetch("current"), *command, "--list")
abort error unless status.success?

FileUtils.mkdir_p(output)
variants.each_key { |name| File.write(File.join(output, "#{name}.jsonl"), "") }
scenarios = JSON.parse(list)
if ENV["BENCH_SCENARIOS"]
  patterns = ENV.fetch("BENCH_SCENARIOS").split(",")
  scenarios.select! { |scenario| patterns.any? { |pattern| scenario.include?(pattern) } }
end
abort "no scenarios selected" if scenarios.empty?
scenarios.each_with_index do |scenario, index|
  order = index.even? ? variants : variants.to_a.reverse.to_h
  order.each do |name, env|
    File.open(File.join(output, "#{name}.jsonl"), "a") do |file|
      abort "#{name}/#{scenario} failed" unless system(env, *command, scenario, out: file)
    end
  end
  puts "#{scenario}: both variants complete"
  $stdout.flush
end
File.write(File.join(output, "run.json"), JSON.pretty_generate(
  command: command,
  variants: variants,
  order: "paired by scenario, alternating baseline/current first",
  repeats: ENV.fetch("REPEATS", "5"),
  batch_seconds: ENV.fetch("BATCH_SECONDS", "0.3"),
) + "\n")
