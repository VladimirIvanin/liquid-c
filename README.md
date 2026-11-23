# Liquid::C

This fork accelerates parsing and rendering with the Liquid 5.14.0 Ruby API.
The native compiler depends on the internal layout of this Liquid release.

## Installation

```ruby
gem "liquid", "= 5.14.0"
gem "liquid-c", github: "VladimirIvanin/liquid-c", branch: "main"
```

Run `bundle install` and load the extension before parsing templates.

```ruby
require "liquid/c"

template = Liquid::Template.parse("Hello, {{ customer.name }}")
template.render!("customer" => { "name" => "Ada" }) # => "Hello, Ada"
```

## Compatibility

The C tokenizer takes UTF-8 input. Templates larger than 16,777,215 bytes
after UTF-8 conversion use the Ruby parser for that document. Custom tags
receive a tokenizer with a `shift` method. Profiling and the
`disable_liquid_c_nodes: true` parse option select Ruby nodes.
Set `Liquid::C.enabled` at application boot when choosing an engine for the
whole process.

The guarded native compiler for built-in tags requires MRI 3.2 and compatible
Liquid methods. A registered subclass of `Liquid::Include` keeps its own parse
and render behavior. Other Ruby versions can still use the C tokenizer, block
body and rendering VM. To inspect variable parser decisions for a template,
pass a hash as the `native_parser_stats:` parse option. The parser populates
it with counts such as `accepted` and `guard_cost`.

Whitespace trimming follows Liquid 5.14.0 by default. Templates that depend on
historical liquid-c whitespace trimming can opt in during parsing with
`bug_compatible_whitespace_trimming: true`.

## Performance

The repository includes deterministic storefront workloads and expected output.
The example below compares plain Liquid 5.14.0 with this extension on the same
Ruby, with YJIT disabled. It uses the nested-include and filter-chain fixtures.

```sh
mkdir -p tmp/bench
DEBUG=false bundle exec rake clean compile
BENCH_ENGINE=pure bundle exec ruby --disable-yjit -Ilib performance/measure.rb nested_include/small filter_chain/small > tmp/bench/pure.jsonl
bundle exec ruby --disable-yjit -Ilib performance/measure.rb nested_include/small filter_chain/small > tmp/bench/current.jsonl
bundle exec ruby performance/compare.rb tmp/bench/pure.jsonl tmp/bench/current.jsonl
```

Each row reports the median time per operation over five samples. Parse builds
the root template. Render reuses a parsed root with a fresh partial cache.
Parse-and-render includes both operations. Speedup is the plain Ruby median
divided by the extension median. Values above one indicate a faster extension.
The runner checks each fixture's output.

On MRI 3.3.13 (x86-64 Linux, YJIT off), the two render fixtures gave the
following allocation counts, rounded to the nearest object per render.

| Fixture | Plain Liquid | Liquid C |
| --- | ---: | ---: |
| `filter_chain/small` | 870 | 510 |
| `nested_include/small` | 800 | 855 |

The benchmark guide also covers
larger scenarios, Hash and Drop inputs, and cold and warm partial caches.
[Benchmark guide](performance/README.md)

## Developing

Install the tools pinned in `mise.toml`, Ruby build prerequisites, a C compiler,
make and Valgrind (Linux). The development bundle uses Ruby 3.3.13.

```sh
mise trust
mise install
mise run setup
mise run check
```

On Linux, `bundle exec rake test:compatibility:sanitizers` builds the extension
with ASan and UBSan. For this check, build MRI with
`--with-setjmp-type=_setjmp` so ASan can track stack unwinding through Ruby
exceptions. The GC stress phase of the sanitizer runner also requires an
ASan-instrumented Ruby.

### Extension compatibility tests

`bundle exec rake test:compatibility:extensions` checks monkey patches, custom
tags and blocks, filter overrides and reloading, decimal conversion, dynamic
drops, layered registers, error recovery, and overlapping renders in two threads.
The fixtures use synthetic data and require neither Rails nor an external app.
Collection scenarios include parsing string conditions in `where_exp` and
`find_exp`, nested filters inside `group_by_exp`, short circuit evaluation,
and restoring bindings after errors. Mutable mapping drops, cached nested
fragments, and clearing template assigns between payloads are also covered.
Language scenarios exercise patched expression parsing, runtime expression
objects, custom condition operators, component regions rendered through a
runtime-created `render` tag, and parent block rendering from a drop.

The suite is included in `bundle exec rake test`. It runs on pure Ruby and the
`c`, `no_vm`, and `disabled` configurations in all four parser modes. Each parsed
template checks its body class; patches installed before loading the extension
are tested in a separate process with a timeout.

```sh
ENGINES=pure,c MODES=warn,strict bundle exec ruby test/compatibility/run.rb extensions
TEST_SEED=90210 bundle exec rake test:compatibility:extensions
```

See the [compatibility corpus guide](test/fixtures/liquid_spec/README.md) for the pinned fixtures and reproduction commands.
