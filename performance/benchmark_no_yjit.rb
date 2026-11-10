# frozen_string_literal: true

require "liquid"
require "liquid/c" if ARGV.shift == "c"
require "benchmark/ips"
require File.join(Gem.loaded_specs.fetch("liquid").full_gem_path, "performance/theme_runner")

abort("Run with --disable-yjit") if defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?

Liquid::Environment.default.error_mode = :lax
profiler = ThemeRunner.new

Benchmark.ips do |x|
  x.time = 20
  x.warmup = 10

  puts
  puts "Running benchmark for #{x.time} seconds (with #{x.warmup} seconds warmup)."
  puts "YJIT: disabled; error mode: lax"
  puts

  x.report("tokenize:") { profiler.tokenize }
  x.report("parse:") { profiler.compile }
  x.report("render:") { profiler.render }
  x.report("parse & render:") { profiler.run }
end
