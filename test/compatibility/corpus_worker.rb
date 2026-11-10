# frozen_string_literal: true

require_relative "boot"
require_relative "corpus"

selection, output = ARGV
raise "Unknown corpus selection: #{selection}" unless ["full", "smoke"].include?(selection)

manifest = Compatibility::Corpus.manifest
entries = manifest.fetch("entries").to_h { |entry| [entry.fetch("id"), entry] }
smoke = manifest.fetch("smoke_ids") if selection == "smoke"
observations = []
Compatibility::Corpus.records.each do |record|
  id = record.fetch("id")
  next if smoke && !smoke.include?(id)
  next if ENV["CASE"] && !id.include?(ENV.fetch("CASE"))

  entries.fetch(id).fetch("modes").each do |mode, status|
    next unless status.fetch("status") == "accepted"

    observation = Compatibility::Corpus.observe(record, mode)
    if Compatibility::ENGINE == "pure" && !Compatibility::Corpus.matches?(record, observation)
      raise "Oracle no longer matches source expectation: #{id} (#{mode}): #{observation.inspect}"
    end

    observations << { id: id, mode: mode, source: record.fetch("source"), result: observation }
  end
end
raise "No corpus cases selected" if observations.empty?

File.write(output, JSON.generate(metadata: Compatibility.verify_engine!, observations: observations) + "\n")
puts "#{observations.size} corpus observations"
