# frozen_string_literal: true

require "bundler/setup"
require "rbconfig"
require_relative "process_runner"

directory = "tmp/coverage/ruby-utils"
FileUtils.mkdir_p(directory)
results = ["pure", "c", "no_vm", "disabled"].map do |engine|
  result = Compatibility::ProcessRunner.run(
    [RbConfig.ruby, "-Ilib", "test/compatibility/slice_coverage.rb", File.join(directory, "#{engine}.json")],
    env: { "LIQUID_ENGINE" => engine, "LIQUID_PARSER_MODE" => "strict", "COVERAGE" => nil },
    log: File.join(directory, "#{engine}.log"),
    timeout: 10,
  )
  puts "#{engine}: #{result[:success] ? "covered" : "failed"}; #{result[:log]}"
  result.merge(engine: engine)
end
File.write(File.join(directory, "results.json"), JSON.pretty_generate(results) + "\n")
exit(results.all? { |result| result[:success] } ? 0 : 1)
