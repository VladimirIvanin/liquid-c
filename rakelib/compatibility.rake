# frozen_string_literal: true

namespace :test do
  namespace :compatibility do
    ["upstream", "regression"].each do |suite|
      desc "Run #{suite} against pure Liquid and three extension configurations"
      task suite => :compile do
        ruby "test/compatibility/run.rb", suite
      end
    end

    desc "Compare curated observations against the pure Liquid oracle"
    task differential: :compile do
      ruby "test/compatibility/compare.rb", "curated"
    end

    desc "Compare deterministic generated templates against the pure Liquid oracle"
    task generated: :compile do
      ruby "test/compatibility/compare.rb", "generated"
    end

    desc "Run isolated GC, crash, and source-size boundary tests"
    task safety: :compile do
      ruby "test/compatibility/safety_runner.rb"
    end

    desc "Collect Ruby coverage while running the compatibility matrix"
    task coverage: :compile do
      FileUtils.rm_f(["tmp/coverage/ruby/.resultset.json", "tmp/coverage/ruby/.last_run.json"])
      sh({ "COVERAGE" => "true" }, RbConfig.ruby, "test/compatibility/run.rb", "all")
    end
    desc "Build an instrumented extension and measure C coverage"
    task c_coverage: :compile do
      ruby "test/compatibility/c_coverage.rb"
    end

    desc "Run isolated safety tests under Valgrind"
    task valgrind: :compile do
      sh(
        { "VALGRIND" => "true", "ENGINES" => "c", "TEST_TIMEOUT" => "600" },
        RbConfig.ruby,
        "test/compatibility/safety_runner.rb",
      )
    end
  end

  desc "Run all compatibility groups, collecting failures from every group"
  task compatibility: :compile do
    commands = [
      ["test/compatibility/harness_test.rb"],
      ["test/compatibility/run.rb", "all"],
      ["test/compatibility/compare.rb", "curated"],
      ["test/compatibility/compare.rb", "generated"],
      ["test/compatibility/safety_runner.rb"],
    ]
    results = commands.map { |args| system(RbConfig.ruby, "-Ilib", *args) }
    abort("Compatibility failures: see tmp/compatibility") unless results.all?
  end
end
