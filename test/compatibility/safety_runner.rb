# frozen_string_literal: true

require "bundler/setup"
require "rbconfig"
require_relative "process_runner"

directory = ENV.fetch("RESULTS_DIR", "tmp/compatibility/safety")
engines = ENV.fetch("ENGINES", "pure,c,no_vm,disabled").split(",")
raise ArgumentError, "Invalid ENGINES" if engines.empty? || (engines - ["pure", "c", "no_vm", "disabled"]).any?

names = File.read(File.join(__dir__, "safety_test.rb")).scan(/^  def (test_\w+)/).flatten
names.select! { |name| name.include?(ENV["CASE"]) } if ENV["CASE"]
raise "No safety tests selected" if names.empty?

results = []
engines.product(names).each do |engine, name|
  label = "#{engine}-#{name}"
  env = {
    "LIQUID_ENGINE" => engine,
    "LIQUID_PARSER_MODE" => "strict",
    "LIQUID_C_DISABLE_VM" => nil,
    "GC_STRESS" => nil,
    "COVERAGE_NAME" => label,
  }
  command = [RbConfig.ruby, "-Ilib", "test/compatibility/safety_test.rb", "--name", name]
  if ENV["VALGRIND"] == "true"
    command = [RbConfig.ruby, "test/compatibility/memcheck.rb", *command.drop(1)]
  end
  result = Compatibility::ProcessRunner.run(
    command,
    env: env,
    log: File.join(directory, "#{label}.log"),
    timeout: Integer(ENV.fetch("TEST_TIMEOUT", name.start_with?("test_adversarial_") ? "10" : "120")),
  )
  results << result.merge(engine: engine, test: name)
  outcome = result[:summary] || "exit=#{result[:exitstatus]} signal=#{result[:signal]} timeout=#{result[:timeout]}"
  puts "#{label}: #{outcome}"
  unless result[:success]
    warn "#{label}: see #{result[:log]}"
    warn File.read(result[:log])
  end
  File.write(File.join(directory, "results.json"), JSON.pretty_generate(results) + "\n")
end
exit(results.all? { |result| result[:success] } ? 0 : 1)
