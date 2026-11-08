# frozen_string_literal: true

require "bundler/setup"
require "rbconfig"
require "zlib"
require_relative "process_runner"

root = File.expand_path("../..", __dir__)
directory = File.join(root, "tmp/coverage/native")
build = File.join(directory, "build")
FileUtils.mkdir_p(build)
Dir[File.join(build, "*.{gcda,gcno,o}")].each { |path| FileUtils.rm_f(path) }
steps = []
Dir.chdir(build) do
  steps << Compatibility::ProcessRunner.run(
    [
      RbConfig.ruby,
      File.join(root, "ext/liquid_c/extconf.rb"),
      # Keep basic loop optimization: the intentional 500,000-level stack
      # exhaustion probe repeatedly scans long lines and times out at -O0.
      "--with-cflags=--coverage -O1 -g",
      "--with-ldflags=--coverage",
    ],
    env: { "DEBUG" => "true" },
    log: File.join(directory, "configure.log"),
    timeout: 120,
  )
  abort("Coverage configuration failed") unless steps.last[:success]
  steps << Compatibility::ProcessRunner.run(
    ["make", "-j2"],
    env: {},
    log: File.join(directory, "build.log"),
    timeout: 120,
  )
  abort("Coverage compilation failed") unless steps.last[:success]
end
Dir.chdir(root) do
  commands = [
    ["run.rb", "all"],
    ["compare.rb", "curated"],
    ["compare.rb", "generated"],
    ["corpus_runner.rb", "smoke"],
    ["safety_runner.rb", "safety"],
  ]
  commands.each do |script, suite|
    steps << Compatibility::ProcessRunner.run(
      [RbConfig.ruby, "-Ilib", "test/compatibility/#{script}", suite],
      env: {
        "LIQUID_C_EXTENSION_DIR" => build,
        "ENGINES" => script == "corpus_runner.rb" ? "pure,c,no_vm,disabled" : "c,no_vm,disabled",
        # Ruby coverage turns on VM tracing, which deliberately disables native
        # frontend optimizations and changes subprocess stdout via SimpleCov.
        "COVERAGE" => nil,
        "RESULTS_DIR" => File.join(directory, suite),
      },
      log: File.join(directory, "#{script}-#{suite}.log"),
      timeout: 600,
    )
  end
end
Dir.chdir(directory) do
  sources = Dir[File.join(root, "ext/liquid_c/*.c")].sort
  steps << Compatibility::ProcessRunner.run(
    ["gcov", "--json-format", "--branch-probabilities", "-o", build, *sources],
    env: {},
    log: File.join(directory, "gcov.log"),
    timeout: 60,
  )
end
files = Dir[File.join(directory, "*.gcov.json.gz")].flat_map do |path|
  Zlib::GzipReader.open(path) { |reader| JSON.parse(reader.read).fetch("files") }
end
files.select! do |file|
  path = file.fetch("file")
  path.start_with?(File.join(root, "ext/liquid_c/")) && path.end_with?(".c")
end
summary = files.map do |file|
  lines = file.fetch("lines")
  branches = lines.flat_map { |line| line.fetch("branches", []) }
  {
    file: file.fetch("file").delete_prefix(root + "/"),
    lines: lines.size,
    covered_lines: lines.count { |line| line.fetch("count") > 0 },
    branches: branches.size,
    covered_branches: branches.count { |branch| branch.fetch("count") > 0 },
  }
end
File.write(File.join(directory, "results.json"), JSON.pretty_generate(steps: steps, coverage: summary) + "\n")
puts JSON.pretty_generate(summary)
exit(steps.all? { |step| step[:success] } ? 0 : 1)
