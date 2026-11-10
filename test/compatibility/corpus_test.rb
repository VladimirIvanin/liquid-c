# frozen_string_literal: true

require_relative "boot"
require_relative "corpus"
require "minitest/autorun"

class CorpusIntegrityTest < Minitest::Test
  def test_manifest_accounts_for_every_case_and_mode
    corpus = Compatibility::Corpus
    manifest = corpus.manifest
    records = corpus.records
    assert_equal(corpus::REVISION, manifest.fetch("revision"))
    manifest.fetch("support_files").each do |name, checksum|
      assert_equal(checksum, corpus.digest(File.join(corpus::DIRECTORY, name)))
    end
    assert_equal(corpus.digest(File.join(corpus::DIRECTORY, "cases.yml")), manifest.fetch("cases_sha256"))
    ids = records.map { |record| record.fetch("id") }
    assert_equal(ids.uniq, ids)
    assert_equal(ids, manifest.fetch("entries").map { |entry| entry.fetch("id") })
    assert_equal(manifest.fetch("source_counts"), records.group_by do |record|
                                                    record.fetch("source")
                                                  end.transform_values(&:size))
    assert_equal(2764, manifest.fetch("source_counts").fetch("specs/shopify_production_recordings/recorded_specs.yml"))
    assert_equal(1905, records.count { |record| record["source"].start_with?("specs/parser_errors/") })
    records.zip(manifest.fetch("entries")).each do |record, entry|
      assert_equal(record.fetch("modes"), entry.fetch("modes").keys)
      entry.fetch("modes").each_value do |result|
        assert_includes(["accepted", "excluded"], result.fetch("status"))
        refute_empty(result.fetch("reason")) if result["status"] == "excluded"
      end
    end
    assert_empty(manifest.fetch("smoke_ids") - ids)
  end

  def test_decoder_preserves_aliases_cycles_and_binary_keys
    shared = [false, nil]
    original = { "a" => shared, "b" => shared, "\xFF".b => 1, 1 => "integer", "1" => "string" }
    original["self"] = original
    decoded = Compatibility::CorpusFixtures.decode(original)
    assert_same(decoded, decoded.fetch("self"))
    assert_same(decoded.fetch("a"), decoded.fetch("b"))
    refute_same(shared, decoded.fetch("a"))
    assert_equal(1, decoded.fetch("\xFF".b))
    assert_equal("integer", decoded.fetch(1))
    assert_equal("string", decoded.fetch("1"))
    normalized = Compatibility::Observation.normalize(original)
    assert_equal(6, normalized.fetch("hash").size)
    refute_equal(normalized["hash"][3][0], normalized["hash"][4][0])
  end

  def test_error_matcher_distinguishes_parse_and_render
    record = { "errors" => { "parse_error" => ["SyntaxError", "Unknown tag"] } }
    error = { class: "Liquid::SyntaxError", message: Compatibility::Observation.normalize("Unknown tag 'bad'") }
    assert(Compatibility::Corpus.matches?(record, { "phase" => "parse", "exception" => error }))
    refute(Compatibility::Corpus.matches?(record, { "phase" => "render", "exception" => error }))
  end

  def test_aliases_to_instantiated_drops_keep_identity
    marker = { "instantiate:NumberDrop" => { "value" => 42 } }
    decoded = Compatibility::CorpusFixtures.decode([marker, marker])
    assert_same(decoded.first, decoded.last)
    assert_equal(42, decoded.first.to_liquid_value)
  end
end
