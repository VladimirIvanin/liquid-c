# frozen_string_literal: true

require "bundler/setup"
require "rbconfig"
require_relative "process_runner"

selection = ARGV.fetch(0, "full")
raise "Unknown corpus selection" unless ["full", "smoke"].include?(selection)

directory = ENV.fetch("RESULTS_DIR", "tmp/compatibility/corpus-#{selection}")
engines = ENV.fetch("ENGINES", "pure,c,no_vm,disabled").split(",")
raise "Invalid engines" unless engines.first == "pure" && (engines - ["pure", "c", "no_vm", "disabled"]).empty?

results = []
differences = []
oracle = nil
engines.each do |engine|
  label = "corpus-#{selection}-#{engine}"
  output = File.join(directory, "#{label}.json")
  FileUtils.rm_f(output)
  result = Compatibility::ProcessRunner.run(
    [RbConfig.ruby, "-Ilib", "test/compatibility/corpus_worker.rb", selection, output],
    env: {
      "LIQUID_ENGINE" => engine,
      "LIQUID_PARSER_MODE" => "strict",
      "LIQUID_C_DISABLE_VM" => nil,
      "GC_STRESS" => nil,
      "COVERAGE_NAME" => label,
    },
    log: File.join(directory, "#{label}.log"),
    timeout: Integer(ENV.fetch("TEST_TIMEOUT", "180")),
  )
  results << result.merge(engine: engine)
  unless result[:success] && File.exist?(output)
    warn "#{label}: failed; see #{result[:log]}"
    break if engine == "pure"

    next
  end
  observations = JSON.parse(File.read(output)).fetch("observations")
  if engine == "pure"
    oracle = observations
  else
    expected_ids = oracle.map { |entry| entry.values_at("id", "mode") }
    actual_ids = observations.map { |entry| entry.values_at("id", "mode") }
    raise "Corpus selection differs" unless expected_ids == actual_ids

    oracle.zip(observations).each do |expected, actual|
      next if expected.fetch("result") == actual.fetch("result")

      differences << {
        engine: engine,
        mode: actual.fetch("mode"),
        id: actual.fetch("id"),
        source: actual.fetch("source"),
        expected: expected.fetch("result"),
        actual: actual.fetch("result"),
      }
    end
  end
  puts "#{label}: #{observations.size} observations"
end
FileUtils.mkdir_p(directory)
File.write(File.join(directory, "differences.json"), JSON.pretty_generate(differences) + "\n")
File.write(
  File.join(directory, "results.json"),
  JSON.pretty_generate(processes: results, differences: differences.size) + "\n",
)
puts "#{differences.size} differences; #{directory}/differences.json"
exit(results.all? { |result| result[:success] } && differences.empty? ? 0 : 1)
