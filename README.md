# Liquid::C
[![Build Status](https://travis-ci.org/Shopify/liquid-c.svg?branch=main)](https://travis-ci.org/Shopify/liquid-c)

> ⚠️ **Warning: This project is no longer maintained. Use at your own risk and consider looking for alternatives or forks that are currently maintained.**

Partial native implementation of Liquid 5.14.x in C. Compatibility tests use Liquid 5.14.0.

The [compatibility corpus guide](test/fixtures/liquid_spec/README.md) documents
slice hook/monkey-patch tests, the pinned external corpus, coverage, and reproduction commands.

## Installation

Add these lines to your application's Gemfile:

    gem 'liquid', '~> 5.14.0'
    gem 'liquid-c', github: 'Shopify/liquid-c', branch: 'main'

And then execute:

    $ bundle

## Usage

    require 'liquid/c'

then just use the documented API for the liquid Gem.

## Restrictions

* Input strings are assumed to be UTF-8 encoded strings
* Tag#parse(tokens) is given a Liquid::Tokenizer object, instead
  of an array of strings, which only implements the shift method
  to get the next token.

## Performance

This fork targets performance without YJIT. Results without JIT are shown first;
YJIT results are included separately for comparison.

Build the extension in release mode before measuring:

```sh
DEBUG=false bundle exec rake clean compile
```

Both comparisons use Ruby 3.3.13, Liquid 5.14.0 and an AMD Ryzen 7 5700U
(x86_64 Linux), with the extension at revision `caa4ed5`. Each operation has a
10-second warmup and a 20-second measurement. Plain Liquid runs first, followed
by Liquid C, in separate processes with `lax` parsing.

### Without YJIT (primary target)

```sh
bundle exec ruby --disable-yjit -Ilib performance/benchmark_no_yjit.rb bare
bundle exec ruby --disable-yjit -Ilib performance/benchmark_no_yjit.rb c
```

This runner uses Liquid's ThemeRunner and the same four operations as the
upstream benchmark, without its call to `RubyVM::YJIT.enable`. It aborts if
YJIT is enabled; passing `--disable-yjit` to the upstream benchmark alone does
not prevent it from enabling YJIT again.

Local results measured across 2026-11-10–11 (Europe/Moscow):

| Operation | Plain Liquid (i/s) | Liquid C (i/s) |
| --- | ---: | ---: |
| tokenize | 392.897 (±14.0%) | 444.975 (±10.3%) |
| parse | 17.560 (±17.1%) | 26.617 (±7.5%) |
| render | 59.220 (±15.2%) | 80.809 (±11.1%) |
| parse & render | 14.176 (±14.1%) | 20.077 (±10.0%) |

In this run, Liquid C was about 1.52× faster for parse, 1.36× for render and
1.42× for parse & render.

### With YJIT

```sh
bundle exec rake compare:lax
```

The upstream Liquid benchmark enables YJIT in both processes. Local results
measured on 2026-11-10:

| Operation | Plain Liquid (i/s) | Liquid C (i/s) |
| --- | ---: | ---: |
| tokenize | 923.852 (±12.1%) | 923.821 (±6.6%) |
| parse | 41.639 (±12.0%) | 40.002 (±7.5%) |
| render | 136.508 (±16.1%) | 98.799 (±8.1%) |
| parse & render | 31.155 (±12.8%) | 25.943 (±7.7%) |

These are indicative results from local runs, not a general speedup claim.
Both comparisons have substantial variability. With YJIT, Liquid C was slower
for render and parse & render in this run. Repeat measurements on your own workload before
drawing conclusions.
The previous Ruby 3.0.2 results came from the original Liquid C README and did
not measure this fork; the runtime and benchmark have also changed since then.

See the [benchmark guide](performance/README.md) for controlled, repeated
measurements and comparisons between engine versions.

## Developing

Install [mise 2026.11.4](https://mise.jdx.dev/getting-started.html), Ruby build
prerequisites, a C compiler, make and Valgrind (Linux).

```sh
mise trust
mise install
mise run setup
mise run check
```

Tool versions are pinned in `mise.toml`; Ruby stays at 3.3.13. The development
bundle requires Ruby 3.2+ for the patched Nokogiri. RuboCop rules are unchanged.
Pre-commit checks Ruby, workflows and staged secrets; pre-push runs the full
check. CI also runs it on pull requests, pushes to `main` and weekly, including
secret history and OSV scans. Dependabot updates gems and Actions weekly.

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

## Contributing

1. Fork it ( http://github.com/Shopify/liquid-c/fork )
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create new Pull Request
