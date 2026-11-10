# frozen_string_literal: true

require_relative "boot"
require "json"
require_relative "scenarios"
require_relative "observation"

kind, output = ARGV
scenarios = Compatibility::Scenarios.public_send(kind)
if (selector = ENV["CASE"])
  selected = scenarios.select { |scenario| scenario[:id] == selector }
  selected = scenarios.select { |scenario| scenario[:id].include?(selector) } if selected.empty?
  scenarios = selected
end
raise "No scenarios selected" if scenarios.empty?

observations = scenarios.map do |scenario|
  {
    id: scenario.fetch(:id),
    input: Compatibility::Observation.normalize(scenario),
    result: Compatibility::Observation.call(scenario),
  }
end
File.write(output, JSON.pretty_generate(metadata: Compatibility.verify_engine!, observations: observations) + "\n")
