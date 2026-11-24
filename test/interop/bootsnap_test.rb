# frozen_string_literal: true

require "test_helper"
require "rbconfig"
require "tmpdir"

# Bootsnap caches load paths and compiled code; the extension must still load
# through it, and a binary built for another Ruby must fail loudly.
class BootsnapTest < Minitest::Test
  LIB = File.expand_path("../../lib", __dir__)

  def test_extension_loads_through_bootsnap_load_path_cache
    begin
      require "bootsnap"
    rescue LoadError
      skip("bootsnap is unavailable")
    end

    Dir.mktmpdir do |cache|
      script = <<~RUBY
        require "bootsnap"
        Bootsnap.setup(cache_dir: #{cache.inspect}, development_mode: false, load_path_cache: true,
          compile_cache_iseq: true, compile_cache_yaml: false)
        $LOAD_PATH.unshift(#{LIB.inspect})
        require "liquid/c"
        puts Liquid::Template.parse("{{ 1 | plus: 2 }}").render!
      RUBY
      2.times do
        output = IO.popen([RbConfig.ruby, "-e", script], err: [:child, :out], &:read)
        assert_equal("3", output.lines.last.to_s.strip, output)
      end
    end
  end

  def test_extension_embeds_the_ruby_it_was_built_for
    extension = $LOADED_FEATURES.find { |path| File.basename(path) == "liquid_c.#{RbConfig::CONFIG["DLEXT"]}" }
    refute_nil(extension)
    binary = File.binread(extension)
    assert_includes(binary, RUBY_PLATFORM)
  end
end
