# frozen_string_literal: true

require "bundler/setup"
require "ruby_memcheck"

available = ENV.fetch("PATH").split(File::PATH_SEPARATOR).any? do |directory|
  File.executable?(File.join(directory, "valgrind"))
end
abort("Valgrind is not installed") unless available

configuration = RubyMemcheck::Configuration.new(binary_name: "liquid_c")
exit(RubyMemcheck::RubyRunner.new(configuration).run(*ARGV))
