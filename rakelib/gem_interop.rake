# frozen_string_literal: true

namespace :test do
  desc "Run scenarios with Sidekiq-style warmup, compaction, threads, fibers, profilers and code reloading"
  Rake::TestTask.new(gem_interop: :compile) do |t|
    t.libs << "lib" << "test"
    t.test_files = FileList["test/interop/**/*_test.rb"]
  end
end
