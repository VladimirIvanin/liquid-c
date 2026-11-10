# frozen_string_literal: true

# Explicit maintenance command. CI consumes committed fixtures without fetching
# or evaluating the source project. See test/fixtures/liquid_spec/README.md.
ENV["LIQUID_ENGINE"] = "pure"
ENV["TZ"] = "UTC"
require_relative "boot"
require_relative "corpus"
require "fileutils"

source_root = File.expand_path(ARGV.fetch(0))
directory = Compatibility::Corpus::DIRECTORY
manifest_path = File.join(directory, "manifest.json")
if File.exist?(manifest_path)
  previous = JSON.parse(File.read(manifest_path))
  if previous.fetch("revision") == Compatibility::Corpus::REVISION
    previous.fetch("files").each do |path, checksum|
      source_path = File.join(source_root, path)
      next if Compatibility::Corpus.digest(source_path) == checksum

      raise "Source differs from pinned revision: #{path}"
    end
  end
end
FileUtils.mkdir_p(directory)
random = Random.new(51400)
records = []
files = {}
counts = {}
fields = [
  "name",
  "template",
  "expected",
  "expected_pattern",
  "environment",
  "filesystem",
  "errors",
  "template_name",
  "resource_limits",
  "exception_renderer",
  "caller_location",
  "context_klass",
  "template_factory",
].freeze

merge = lambda do |left, right|
  left.merge(right) { |_key, a, b| a.is_a?(Hash) && b.is_a?(Hash) ? merge.call(a, b) : b }
end

["basics", "parser_errors", "shopify_production_recordings"].each do |suite|
  base = File.join(source_root, "specs", suite)
  config = Compatibility::Corpus.load_yaml(File.join(base, "suite.yml"))
  files["specs/#{suite}/suite.yml"] = Compatibility::Corpus.digest(File.join(base, "suite.yml"))
  defaults = config.fetch("defaults", {}).transform_keys(&:to_s)
  Dir[File.join(base, "*.yml")].sort.each do |path|
    next if File.basename(path) == "suite.yml"

    relative = path.delete_prefix(source_root + "/")
    files[relative] = Compatibility::Corpus.digest(path)
    # One upstream file contains appended cases after a document-end marker.
    # Keep the single anchor namespace: later cases reference earlier anchors.
    content = File.read(path).gsub(/^\.\.\.[ \t]*$/, "")
    document = YAML.safe_load(content, permitted_classes: [Symbol, Date, Time, Range, Regexp], aliases: true)
    metadata = document.is_a?(Hash) ? document.fetch("_metadata", {}) : {}
    entries = document.is_a?(Array) ? document : document.fetch("specs")
    counts[relative] = entries.size
    shared = Array(metadata["data_files"]).reduce({}) do |data, name|
      data_path = File.join(File.dirname(path), name)
      files[data_path.delete_prefix(source_root + "/")] = Compatibility::Corpus.digest(data_path)
      merge.call(data, Compatibility::Corpus.load_yaml(data_path))
    end
    entries.each_with_index do |entry, index|
      record = entry.slice(*fields)
      record["source"] = relative
      record["index"] = index
      record["id"] = "#{relative}:#{index}:#{entry.fetch("name")}"
      record["features"] =
        (config.fetch("features", []) + metadata.fetch("features", []) + entry.fetch("features", [])).uniq
      options = metadata.fetch("required_options", {}).transform_keys(&:to_s)
      modes = entry.fetch("error_mode", options.delete("error_mode") { defaults["error_mode"] })
      record["modes"] = modes ? Array(modes).map { |mode| mode.to_s.delete_prefix(":") } : Compatibility::Corpus::MODES
      record["render_errors"] =
        entry.fetch("render_errors", metadata.fetch("render_errors", defaults.fetch("render_errors", false)))
      record["options"] = options unless options.empty?
      record["environment"] = merge.call(shared, entry.fetch("environment", {})) unless shared.empty?
      if entry["generate"]
        values = entry.fetch("generate").transform_values do |spec|
          spec.is_a?(Hash) ? random.rand(spec.fetch("min", 0)..spec.fetch("max", 1000)) : spec
        end
        ["template", "expected"].each do |key|
          record[key] = record.fetch(key).gsub(/\#\{(n|n \* n)\}/) do
            expression = Regexp.last_match(1)
            (expression == "n" ? values.fetch("n") : values.fetch("n")**2).to_s
          end
        end
        record["generated"] = values
      end
      records << record
    end
  end
end
raise "Duplicate case IDs" unless records.map { |record| record.fetch("id") }.uniq.size == records.size

recorded = records.count { |record| record["source"] == "specs/shopify_production_recordings/recorded_specs.yml" }
raise "Truncated production recordings: #{recorded}" unless recorded == 2764

File.write(File.join(directory, "cases.yml"), YAML.dump(records))
support_files = {
  "lib/liquid/spec/deps/standard_drops.rb" => "standard_drops.rb",
  "lib/liquid/spec/time_freezer.rb" => "time_freezer.rb",
  "LICENSE.txt" => "LICENSE",
}
support_files.each do |source, target|
  path = File.join(source_root, source)
  files[source] = Compatibility::Corpus.digest(path)
  content = File.read(path)
  content = content.split("# Register all standard drops").first if target == "standard_drops.rb"
  File.write(File.join(directory, target), content)
end
entries = records.map.with_index do |record, index|
  features = record.fetch("features") & Compatibility::Corpus::SHOPIFY_FEATURES
  reason = if !features.empty?
    "Requires #{features.join(", ")}"
  elsif record["context_klass"]
    "Source context_klass is a serialized hash, not a reconstructible Context class"
  end
  results = record.fetch("modes").to_h do |mode|
    if reason
      [mode, { "status" => "excluded", "reason" => reason }]
    else
      observation = Compatibility::Corpus.observe(record, mode)
      if Compatibility::Corpus.matches?(record, observation)
        [mode, { "status" => "accepted" }]
      else
        [
          mode,
          {
            "status" => "excluded",
            "reason" => "Source expectation differs from pure Liquid 5.14.0",
            "observation" => observation,
          },
        ]
      end
    end
  end
  puts "Validated #{index + 1}/#{records.size}" if (index + 1) % 500 == 0
  { "id" => record.fetch("id"), "source" => record.fetch("source"), "name" => record.fetch("name"), "modes" => results }
end
manifest = {
  "repository" => "https://github.com/Shopify/liquid-spec",
  "revision" => Compatibility::Corpus::REVISION,
  "seed" => 51400,
  "oracle" => Liquid::VERSION,
  "oracle_ruby" => RUBY_DESCRIPTION,
  "files" => files,
  "source_counts" => counts,
  "cases_sha256" => Compatibility::Corpus.digest(File.join(directory, "cases.yml")),
  "entries" => entries,
  "support_files" => support_files.values.to_h do |name|
                       [name, Compatibility::Corpus.digest(File.join(directory, name))]
                     end,
}
groups = {
  "short_circuit" => /if_short_circuit_conditions/,
  "bounds" => /for_loop_bounds_permutations/,
  "where" => /where_with_all_permutations/,
  "division" => /divided_by_with_permutation/,
  "array_equality" => /array_equality/,
  "equality" => /test_equality_/,
  "comparisons" => /comparison_operators/,
  "uncomparable" => /errors_when_comparing_uncomparable/,
  "big_integers" => /big_integers/,
  "binary" => /binary/,
  "utf8" => /utf8/,
  "usascii" => /usascii/,
  "weird_keys" => /weird_keys/,
  "contains" => /contains/,
  "include_binding" => /include_binds_the_expression/,
}
groups.transform_values! { |pattern| %r{shopify_production_recordings/.*#{pattern.source}} }
[
  "filter-nil-safety",
  "filter-edge-cases",
  "type-coercion",
  "truthiness",
  "truthiness_matrix",
  "boolean-chains",
  "interrupts",
  "inline-errors",
  "range-resource-limits",
  "recursion",
  "security",
].each { |name| groups[name] = %r{basics/#{Regexp.escape(name)}\.yml} }
accepted = entries.select { |entry| entry["modes"].any? { |_mode, result| result["status"] == "accepted" } }
manifest["smoke_groups"] = {}
manifest["smoke_exclusions"] = {}
groups.each do |name, pattern|
  if (entry = accepted.find { |candidate| candidate.fetch("id").match?(pattern) })
    manifest["smoke_groups"][name] = entry.fetch("id")
  else
    candidates = entries.select { |candidate| candidate.fetch("id").match?(pattern) }
    raise "Missing smoke group: #{name}" if candidates.empty?

    manifest["smoke_exclusions"][name] = candidates.map { |candidate| candidate.slice("id", "modes") }
  end
end
manifest["smoke_ids"] = (manifest["smoke_groups"].values + accepted.select do |entry|
  entry["source"].end_with?("adversarial_boundaries.yml")
end.map { |entry| entry["id"] }).uniq
File.write(File.join(directory, "manifest.json"), JSON.pretty_generate(manifest) + "\n")
puts "Imported #{records.size} cases; #{entries.sum do |entry|
  entry["modes"].count do |_mode, result|
    result["status"] == "accepted"
  end
end} accepted case/mode pairs"
