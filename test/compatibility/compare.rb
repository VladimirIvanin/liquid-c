# frozen_string_literal: true

require "bundler/setup"
require "rbconfig"
require_relative "process_runner"

kind = ARGV.fetch(0, "curated")
raise ArgumentError, kind unless ["curated", "generated"].include?(kind)

root = File.expand_path("../..", __dir__)
Dir.chdir(root)
directory = ENV.fetch("RESULTS_DIR", "tmp/compatibility/#{kind}")
FileUtils.mkdir_p(directory)
processes = []
differences = []
comparisons = 0
modes = ENV.fetch("MODES", "lax,warn,strict,strict2").split(",")
raise ArgumentError, "Invalid MODES" if modes.empty? || (modes - ["lax", "warn", "strict", "strict2"]).any?

modes.each do |mode|
  oracle = nil
  ["pure", "c", "no_vm", "disabled"].each do |engine|
    label = "#{kind}-#{engine}-#{mode}"
    output = File.join(directory, "#{label}.json")
    FileUtils.rm_f(output)
    env = {
      "LIQUID_ENGINE" => engine,
      "LIQUID_PARSER_MODE" => mode,
      "LIQUID_C_DISABLE_VM" => nil,
      "GC_STRESS" => nil,
      "COVERAGE_NAME" => label,
    }
    result = Compatibility::ProcessRunner.run(
      [RbConfig.ruby, "-Ilib", "test/compatibility/worker.rb", kind, output],
      env: env,
      log: File.join(directory, "#{label}.log"),
      timeout: Integer(ENV.fetch("TEST_TIMEOUT", "120")),
    )
    processes << result
    unless result[:success] && File.exist?(output)
      warn "#{label}: process failure, see #{result[:log]}"
      break if engine == "pure"

      next
    end
    observations = JSON.parse(File.read(output)).fetch("observations")
    if engine == "pure"
      oracle = observations
      puts "#{label}: #{oracle.size} oracle observations"
      next
    end
    raise "Scenario IDs differ" unless oracle.map { |entry| entry["id"] } == observations.map { |entry| entry["id"] }

    before = differences.size
    oracle.zip(observations).each do |expected, actual|
      comparisons += 1
      next if expected["result"] == actual["result"]

      differences << {
        engine: engine,
        mode: mode,
        id: expected["id"],
        input: expected["input"],
        expected: expected["result"],
        actual: actual["result"],
      }
    end
    puts "#{label}: #{differences.size - before}/#{observations.size} differences"
  end
end
File.write(File.join(directory, "differences.json"), JSON.pretty_generate(differences) + "\n")
File.write(File.join(directory, "results.json"), JSON.pretty_generate(
  processes: processes,
  comparisons: comparisons,
  differences: differences.size,
  seed: ENV.fetch("GENERATOR_SEED", "51400"),
) + "\n")
puts "#{comparisons} comparisons, #{differences.size} differences; #{directory}/differences.json"
exit(differences.empty? && processes.all? { |result| result[:success] } ? 0 : 1)
