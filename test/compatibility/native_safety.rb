# frozen_string_literal: true

require "bundler/setup"
require "rbconfig"
require "open3"
require_relative "process_runner"

mode = ARGV.fetch(0, "allocations")
raise ArgumentError, mode unless ["allocations", "sanitizers", "valgrind"].include?(mode)

root = File.expand_path("../..", __dir__)
directory = File.join(root, "tmp/native-safety", "#{RUBY_ENGINE}-#{RUBY_VERSION}", mode)
build = File.join(directory, "build")
FileUtils.mkdir_p(build)
steps = []
run = lambda do |command, env, name, timeout = 180|
  result = Compatibility::ProcessRunner.run(
    command,
    env: env,
    log: File.join(directory, "#{name}.log"),
    timeout: timeout,
  )
  steps << result
  File.write(File.join(directory, "results.json"), JSON.pretty_generate(steps) + "\n")
  abort("#{name} failed: #{result[:log]}") unless result[:success]

  puts "#{name}: passed"
end
configure = [RbConfig.ruby, File.join(root, "ext/liquid_c/extconf.rb")]
if mode == "sanitizers"
  configure.push(
    "--with-cflags=-O1 -g -fno-omit-frame-pointer -fsanitize=address,undefined",
    "--with-ldflags=-fsanitize=address,undefined",
  )
end
Dir.chdir(build) do
  run.call(configure, { "DEBUG" => "false", "LIQUID_C_TEST_ALLOC_FAILURES" => "true" }, "configure")
  run.call(["make", "clean"], {}, "clean")
  run.call(["make", "-j2"], {}, "compile")
end
env = { "LIQUID_C_EXTENSION_DIR" => build }
if mode == "sanitizers"
  runtime, status = Open3.capture2(*Shellwords.split(RbConfig::CONFIG.fetch("CC")), "-print-file-name=libasan.so")
  runtime = runtime.strip
  abort("ASan runtime not found") unless status.success? && File.file?(runtime)
  env.merge!(
    "LD_PRELOAD" => runtime,
    "ASAN_OPTIONS" => "detect_leaks=0:handle_segv=0:use_sigaltstack=0",
    "UBSAN_OPTIONS" => "halt_on_error=1",
  )
end
Dir.chdir(root) do
  if mode != "allocations"
    tests = "require_relative 'test/unit/native_parser_test'; require_relative 'test/unit/native_tags_test'; " \
      "require_relative 'test/unit/audit_regression_test'"
    command = [RbConfig.ruby, "-Ilib", "-Itest", "-e", tests]
    command.insert(1, "test/compatibility/memcheck.rb") if mode == "valgrind"
    run.call(command, env, "regressions", 300)
  end
  command = [RbConfig.ruby, "test/assembler_allocation_failure.rb"]
  command.insert(1, "test/compatibility/memcheck.rb") if mode == "valgrind"
  run.call(command, env, "allocation-failures", 300)
end
