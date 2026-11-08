# frozen_string_literal: true

require "json"

before, after = ARGV.map do |path|
  File.readlines(path, chomp: true).map { |line| JSON.parse(line) }
    .to_h { |row| [[row.fetch("scenario"), row.fetch("mode")], row] }
end
abort "usage: ruby performance/compare.rb BEFORE.jsonl AFTER.jsonl" unless before && after
abort "scenario sets differ" unless before.keys.sort == after.keys.sort

puts "| Scenario / phase | Before, µs | After, µs | Speed ratio | Objects before → after | Spread after, µs |"
puts "|---|---:|---:|---:|---:|---:|"
before.each do |key, old|
  current = after.fetch(key)
  ["ruby", "yjit", "liquid", "output_sha256"].each do |field|
    abort "incomparable #{key}: #{field}" unless old[field] == current[field]
  end
  abort "at least five samples required" unless [old, current].all? { |row| row.fetch("samples").size >= 5 }

  ratio = old.fetch("median_seconds") / current.fetch("median_seconds")
  puts format(
    "| %s / %s | %.2f | %.2f | %.3f× | %.1f → %.1f | %.2f–%.2f |",
    *key,
    old.fetch("median_seconds") * 1e6,
    current.fetch("median_seconds") * 1e6,
    ratio,
    old.fetch("allocations"),
    current.fetch("allocations"),
    current.fetch("min_seconds") * 1e6,
    current.fetch("max_seconds") * 1e6,
  )
end
