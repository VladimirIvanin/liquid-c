# frozen_string_literal: true

source "https://rubygems.org"
git_source(:github) do |repo_name|
  "https://github.com/#{repo_name}.git"
end

gemspec development_group: :test

gem "liquid", github: "Shopify/liquid", ref: "4e39ae4cc3da73921923c0669e0fc84a66b2f696" # v5.14.0

group :test do
  gem "simplecov", "~> 0.22.0", require: false
  gem "lru_redux", "~> 1.1"
  gem "nokogiri", "~> 1.19.7", force_ruby_platform: true
  gem "base64", require: false # for older rubocop on Ruby 3.4
  gem "rubocop", "~> 1.61.0", require: false
  gem "rubocop-performance", "~> 1.13.2", require: false
  gem "rubocop-shopify", "~> 2.15.1", require: false
  gem "spy", "0.4.1"
  gem "benchmark"
  gem "benchmark-ips"
  gem "ruby_memcheck"
  gem "stackprof", "~> 0.2.28", require: false
end

group :development do
  gem "byebug"
  gem "vernier", "~> 1.11.0", require: false
end
