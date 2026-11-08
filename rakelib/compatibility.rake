# frozen_string_literal: true

namespace :test do
  namespace :compatibility do
    ["upstream", "regression", "extensions", "slice", "expansion"].each do |suite|
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

    desc "Compare all pinned liquid-spec cases with pure Liquid"
    task corpus: :compile do
      ruby "test/compatibility/corpus_test.rb"
      ruby "test/compatibility/corpus_runner.rb", "full"
    end

    desc "Run isolated GC, crash, and source-size boundary tests"
    task safety: :compile do
      ruby "test/compatibility/safety_runner.rb"
    end

    ["allocations", "sanitizers", "valgrind_native"].each do |kind|
      desc "Build an isolated extension and check native #{kind}"
      task kind do
        mode = kind == "valgrind_native" ? "valgrind" : kind
        ruby "test/compatibility/native_safety.rb", mode
      end
    end

    desc "Collect Ruby coverage while running the compatibility matrix"
    task coverage: :compile do
      FileUtils.rm_f(["tmp/coverage/ruby/.resultset.json", "tmp/coverage/ruby/.last_run.json"])
      # C-only dispatch counter tests require tracing to be off. Those run in
      # the normal and native coverage matrices, not under SimpleCov.
      ["upstream", "regression", "extensions", "slice", "expansion"].each do |suite|
        sh({ "COVERAGE" => "true" }, RbConfig.ruby, "test/compatibility/run.rb", suite)
      end
      ruby "test/compatibility/slice_coverage_runner.rb"
    end

    desc "Verify both upstream slice_collection branches for all engines"
    task slice_coverage: :compile do
      ruby "test/compatibility/slice_coverage_runner.rb"
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
      ["test/compatibility/corpus_test.rb"],
      ["test/compatibility/corpus_runner.rb", "smoke"],
      ["test/compatibility/run.rb", "all"],
      ["test/compatibility/compare.rb", "curated"],
      ["test/compatibility/compare.rb", "generated"],
      ["test/compatibility/safety_runner.rb"],
      ["test/compatibility/native_safety.rb", "allocations"],
    ]
    results = commands.map { |args| system(RbConfig.ruby, "-Ilib", *args) }
    abort("Compatibility failures: see tmp/compatibility") unless results.all?
  end
end
