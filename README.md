# Liquid::C
[![Build Status](https://travis-ci.org/Shopify/liquid-c.svg?branch=main)](https://travis-ci.org/Shopify/liquid-c)

> ⚠️ **Warning: This project is no longer maintained. Use at your own risk and consider looking for alternatives or forks that are currently maintained.**

Partial native implementation of the liquid ruby gem in C.

## Installation

Add these lines to your application's Gemfile:

    gem 'liquid', github: 'Shopify/liquid', branch: 'main'
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

To compare Liquid-C's performance with plain Liquid run

    bundle exec rake compare:lax

The latest benchmark results are shown below:

```
$ bundle exec rake compare:lax
/home/spin/.rubies/ruby-3.0.2/bin/ruby ./performance.rb bare benchmark lax

Running benchmark for 10 seconds (with 5 seconds warmup).

Warming up --------------------------------------
              parse:     2.000  i/100ms
             render:     8.000  i/100ms
     parse & render:     2.000  i/100ms
Calculating -------------------------------------
              parse:     29.527  (± 3.4%) i/s -    296.000  in  10.034520s
             render:     89.403  (± 6.7%) i/s -    896.000  in  10.072939s
     parse & render:     20.474  (± 4.9%) i/s -    206.000  in  10.072806s

/home/spin/.rubies/ruby-3.0.2/bin/ruby ./performance.rb c benchmark lax

Running benchmark for 10 seconds (with 5 seconds warmup).

Warming up --------------------------------------
              parse:    10.000  i/100ms
             render:    18.000  i/100ms
     parse & render:     5.000  i/100ms
Calculating -------------------------------------
              parse:     90.672  (± 3.3%) i/s -    910.000  in  10.051124s
             render:    163.871  (± 4.9%) i/s -      1.638k in  10.018105s
     parse & render:     50.165  (± 4.0%) i/s -    505.000  in  10.077377s
```

## Developing

Install [mise 2026.11.4](https://mise.jdx.dev/getting-started.html), Ruby build
prerequisites, a C compiler, make and Valgrind (Linux).

```sh
mise trust
mise install
mise run setup
mise run check
```

Tool versions are pinned in `mise.toml`; Ruby stays at 3.3.0. The development
bundle requires Ruby 3.2+ for the patched Nokogiri. RuboCop rules are unchanged.
Pre-commit checks Ruby, workflows and staged secrets; pre-push runs the full
check. CI also runs it on pull requests, pushes to `main` and weekly, including
secret history and OSV scans. Dependabot updates gems and Actions weekly.

## Contributing

1. Fork it ( http://github.com/Shopify/liquid-c/fork )
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create new Pull Request
