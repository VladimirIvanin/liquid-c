# frozen_string_literal: true

require "bundler/setup"
require "rbconfig"
require_relative "process_runner"

root = File.expand_path("../..", __dir__)
Dir.chdir(root)
suite = ARGV.fetch(0, "all")
engines = ENV.fetch("ENGINES", "pure,c,no_vm,disabled").split(",")
modes = ENV.fetch("MODES", "lax,warn,strict,strict2").split(",")
raise ArgumentError, "Invalid ENGINES" if engines.empty? || (engines - ["pure", "c", "no_vm", "disabled"]).any?
raise ArgumentError, "Invalid MODES" if modes.empty? || (modes - ["lax", "warn", "strict", "strict2"]).any?

timeout = Integer(ENV.fetch("TEST_TIMEOUT", "180"))
results_dir = ENV.fetch("RESULTS_DIR", "tmp/compatibility/#{suite}")
FileUtils.mkdir_p(results_dir)
results = []
test_options = ARGV.drop(1)
unless test_options.any? { |option| option == "--seed" || option.start_with?("--seed=", "-s") }
  test_options += ["--seed", ENV.fetch("TEST_SEED", "51400")]
end
suites = {
  "legacy" => "test/unit_test.rb",
  "upstream" => "test/upstream_test.rb",
  "regression" => "test/compatibility/regression_test.rb",
}
selected = suite == "all" ? suites.keys : [suite]
selected.each do |name|
  script = suites.fetch(name)
  configurations = name == "legacy" ? [["c", "lax"]] : engines.product(modes)
  configurations.each do |engine, mode|
    label = "#{name}-#{engine}-#{mode}"
    env = {
      "LIQUID_ENGINE" => engine,
      "LIQUID_PARSER_MODE" => mode,
      "LIQUID_C_DISABLE_VM" => nil,
      "GC_STRESS" => nil,
      "COVERAGE_NAME" => label,
    }
    result = Compatibility::ProcessRunner.run(
      [RbConfig.ruby, "-Ilib", script, *test_options],
      env: env,
      log: File.join(results_dir, "#{label}.log"),
      timeout: timeout,
    )
    results << result.merge(suite: name, engine: engine, mode: mode)
    outcome = result[:summary] || "exit=#{result[:exitstatus]} signal=#{result[:signal]} timeout=#{result[:timeout]}"
    puts "#{label}: #{outcome}"
    File.write(File.join(results_dir, "results.json"), JSON.pretty_generate(results) + "\n")
  end
end
exit(results.all? { |result| result[:success] } ? 0 : 1)
