# frozen_string_literal: true

require "coverage"
Coverage.start(lines: true, branches: true)
require_relative "boot"
require_relative "slice_fixtures"
require "json"

drop = Compatibility::LazySliceDrop.new
context = Liquid::Context.new("items" => drop, "prefix" => "coverage")
["", "limit: 2", "offset: 1", "offset: 1 limit: 2"].each do |attributes|
  source = "{% for x in items #{attributes} %}{{ x }}{% endfor %}"
  Liquid::Template.parse(source, error_mode: :strict).render!(context)
end
path = File.join(Gem.loaded_specs.fetch("liquid").full_gem_path, "lib/liquid/utils.rb")
coverage = Coverage.result.fetch(path)
dispatch = coverage.fetch(:branches).find { |location, _branches| location[2] == 9 }
raise "slice_collection dispatch is missing" unless dispatch
raise "slice_collection dispatch is not fully covered" unless dispatch.last.values.all?(&:positive?)

report = {
  engine: Compatibility::ENGINE,
  ruby: RUBY_DESCRIPTION,
  source: path,
  lines: coverage.fetch(:lines).slice(7, 7),
  branches: dispatch.last.map { |location, count| { location: location, count: count } },
}
File.write(ARGV.fetch(0), JSON.pretty_generate(report) + "\n")
puts "#{Compatibility::ENGINE}: both slice_collection branches covered"
