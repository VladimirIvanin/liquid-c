# coding: utf-8
# frozen_string_literal: true

lib = File.expand_path("../lib", __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "liquid/c/version"

Gem::Specification.new do |spec|
  spec.name          = "liquid5-c"
  spec.version       = Liquid::C::VERSION
  spec.authors       = ["Justin Li", "Dylan Thacker-Smith", "Vladimir Ivanin"]
  spec.summary       = "Native parser and rendering VM for Liquid 5.14.0"
  spec.homepage      = "https://github.com/VladimirIvanin/liquid-c"
  spec.license       = "MIT"

  spec.extensions    = ["ext/liquid_c/extconf.rb"]
  spec.files         = Dir.chdir(__dir__) { Dir["lib/**/*.rb", "ext/liquid_c/*.{c,h,rb}", "README.md", "LICENSE.txt"] }
  spec.require_paths = ["lib"]

  spec.required_ruby_version = ">= 3.0.0"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["source_code_uri"] = "#{spec.homepage}/tree/v#{spec.version}"

  spec.add_dependency("liquid", "= 5.14.0")
  # Liquid 5.14.0 requires base64 in its standard filters.
  spec.add_dependency("base64", "~> 0.2")
  # strscan 3.1.8 can misread Liquid tokens during GC compaction on MRI.
  spec.add_dependency("strscan", "!= 3.1.8")
end
