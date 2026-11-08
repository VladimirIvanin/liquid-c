# Pinned Liquid compatibility corpus

Source: [Shopify/liquid-spec](https://github.com/Shopify/liquid-spec/tree/84bf25e0edbca5f7e530574788b0f875ab331f50),
revision `84bf25e0edbca5f7e530574788b0f875ab331f50`, MIT license (see `LICENSE`).
The standard Drops and clock helper are copied from that revision; the Drop
registration footer is omitted because this harness uses an explicit local
factory registry. They are excluded from RuboCop as third-party source.

## Running

```sh
bundle exec rake test:compatibility:slice
bundle exec rake test:compatibility:expansion
bundle exec rake test:compatibility:corpus
bundle exec rake test:compatibility:slice_coverage
```

`bundle exec rake test` includes the local regressions, fixture integrity checks,
and the fixed corpus smoke selection. The full corpus runs in the weekly/manual
Ruby 3.3 CI job. Tests read committed files and never need network access or the
liquid-spec gem. Results and per-engine logs are under
`tmp/compatibility/corpus-{smoke,full}`. Differences include source ID, mode,
engine, Ruby observation, and actual observation; strings retain bytes and
encoding. To narrow a reproduction:

```sh
CASE=inline_comment bundle exec ruby -Ilib test/compatibility/corpus_runner.rb full
CASE=adversarial bundle exec ruby -Ilib test/compatibility/safety_runner.rb
```

The isolated adversarial cases have an external 10-second process timeout. This
is a hang guard, not a timing benchmark. An explicit `TEST_TIMEOUT` overrides it
for instrumented runs. The existing native coverage task runs the new matrix
groups and corpus smoke cases. `slice_coverage` separately verifies the original
Ruby `Utils.slice_collection` branch counts and writes reports to
`tmp/coverage/ruby-utils`, because the dependency is outside SimpleCov's project
root.

Ruby and C coverage are separate runs. Ruby VM tracing intentionally disables
some native frontend optimizations, so the C coverage task does not activate
SimpleCov. The Ruby coverage task runs upstream/regression/extension/slice groups;
C-only dispatch counters run in the normal and C coverage matrices.

## Import and provenance

Download/extract the exact source revision, then run the maintenance command:

```sh
mkdir -p tmp/liquid-spec-source
curl -fL https://codeload.github.com/Shopify/liquid-spec/tar.gz/84bf25e0edbca5f7e530574788b0f875ab331f50 \
  -o tmp/liquid-spec-source/source.tar.gz
tar -xzf tmp/liquid-spec-source/source.tar.gz -C tmp/liquid-spec-source --strip-components=1
bundle exec ruby -Ilib test/compatibility/import_corpus.rb tmp/liquid-spec-source
```

The importer uses only pure Liquid 5.14.0, preserving upstream expectations.
`cases.yml` contains all 5649 source cases from `basics`, `parser_errors`, and
`shopify_production_recordings`, including excluded cases. IDs contain the source
file, zero-based entry index, and original name: upstream names are not unique.

`manifest.json` records source SHA256s, counts, the import seed, helper checksums,
the normalized corpus checksum, and accepted/excluded status for every declared
case/mode pair. Source mismatches retain the pure observation and the original
expectation in `cases.yml`. Inspect these exclusions when updating the corpus;
they are not liquid-c failures or permission to suppress engine differences.
The importer must run again when fixtures or their interpretation changes.

Suite/file defaults are materialized. Unrestricted cases run in all four parser
modes; explicit modes are retained, and `parser_errors` defaults to `strict2`.
The two generated Drop inputs use `Random.new(51400)`; only their known numeric
interpolations are expanded, without evaluating Ruby from YAML. The upstream
clock is frozen at 2024-01-01 00:01:58 UTC. Each observation receives fresh
assigns, Drops, environment, filesystem, registers, and resource limits. YAML
aliases, recursive collections, binary strings, and non-string keys survive
decoding. Error checks distinguish parse, raised render, and inline output.

`recorded_specs.yml` has a document-end marker followed by more entries. Ordinary
Ruby YAML loading reads just 2235 of its 2764 cases. The importer removes that
standalone marker before loading, retaining the anchor namespace (later entries
reference earlier anchors). Integrity tests require all 2764 entries and all 1905
parser-error cases.

Shopify-only features and ActiveSupport-dependent cases are explicitly excluded.
Malformed recorded `context_klass` payloads are excluded rather than guessed.
Other expectations are admitted only in modes where pure Liquid matches them;
this includes differences between port behavior and Shopify Liquid. No Python
digit ceiling, Python nesting constant, or LiquidJS-only resource-limit API is
introduced. Source metadata for each exclusion remains in the manifest.

The smoke manifest selects one applicable production case per matrix group, one
case per requested basics group, and all four adversarial grammar boundaries.
`include_binds_the_expression` requires Shopify's include extension, so its
exclusions are recorded under `smoke_exclusions`; a local regression separately
checks Ruby's supported `include ... with` binding.

## Synthetic slice patches

`slice_test.rb` uses two deliberately local patches, not code attributed to a
third-party application. `SlicePrefixPatch` wraps `LazySliceDrop#load_slice`,
calls `super`, records bounds/context, and prefixes selected values using the
current context. `SliceUtilsPatch` delegates unbounded iteration of that Drop to
`load_slice(0, nil)` while passing other collections to `super`.

The tests install patches before extension loading, before compilation, after
compilation, and between renders. Distinct outputs and a tripwire in `each`
detect stale method dispatch and unwanted full materialization. Temporary
prepend methods are removed in `ensure`; preload tests run in subprocesses.
