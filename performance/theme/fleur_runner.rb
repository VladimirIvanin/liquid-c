# frozen_string_literal: true

require_relative "fleur_workloads"
require_relative "fleur_include_workloads"

# Synthetic data-backed Drops exercise Liquid's public Drop protocol. They do
# not simulate database queries, lazy loading or application-specific Drops.
class FleurRecordDrop < Liquid::Drop
  def initialize(values)
    super()
    @values = values
  end

  def liquid_method_missing(name)
    return @values[name] if @values.key?(name)

    super
  end
end

class FleurThemeRunner
  class FileSystem
    attr_reader :reads

    def initialize(partials)
      @partials = partials
      @reads = 0
    end

    def read_template_file(name, *)
      @reads += 1
      @partials.fetch(name)
    end
  end

  attr_reader :name, :fixture, :data_mode

  def self.fixtures
    FleurWorkloads.build + FleurIncludeWorkloads.build
  end

  def initialize(fixture, data_mode:, parse_options:)
    @fixture = fixture
    @data_mode = data_mode
    @name = "fleur_#{fixture.fetch(:name)}_#{data_mode}"
    @parse_options = parse_options
    @filesystem = FileSystem.new(fixture.fetch(:partials))
    @assigns = prepare_assigns(fixture.fetch(:assigns))
    @compiled = compile
    @warm_partials = {}
    # Prime compiled partials outside timing; registers other than this cache
    # are newly created for every render, including warm-partial measurements.
    assert_output(render_with(@compiled, @assigns, @warm_partials), fixture.fetch(:expected))
  end

  def compile
    Liquid::Template.new.parse(@fixture.fetch(:source), @parse_options)
  end

  def compile_all
    # Static corpus throughput, not dependency discovery: each declared source
    # is parsed once with its own parse context. Real include loading is measured
    # by render (cold partials) and run, which use the engines' normal caches.
    root = compile
    @fixture.fetch(:partials).each_value do |source|
      Liquid::Template.new.parse(source, @parse_options)
    end
    root
  end

  def render
    render_with(@compiled, @assigns, {})
  end

  def render_warm_partials
    render_with(@compiled, @assigns, @warm_partials)
  end

  def run
    render_with(compile, @assigns, {})
  end

  def verify!
    # Same template and same compiled partial cache, changing data in between:
    # catches stale values, leaked temporary assigns and output-only memoization.
    template = compile
    cache = {}
    assert_output(render_with(template, @assigns, cache), @fixture.fetch(:expected))
    reads = @filesystem.reads
    assert_output(render_with(template, @assigns, cache), @fixture.fetch(:expected))
    raise "#{@name}: warm cache reread a partial" unless @filesystem.reads == reads

    if (alternate = @fixture[:alternate])
      assert_output(render_with(template, prepare_assigns(alternate.fetch(:assigns)), cache), alternate.fetch(:expected))
      assert_output(render_with(template, @assigns, cache), @fixture.fetch(:expected))
    end
    assert_output(render, @fixture.fetch(:expected))
    assert_output(render_warm_partials, @fixture.fetch(:expected))
    assert_output(run, @fixture.fetch(:expected))
    assert_output(render_with(compile_all, @assigns, {}), @fixture.fetch(:expected))
    @fixture.fetch(:expected)
  end

  def metadata
    {
      scenario: @name, templates: 1, partials: @fixture.fetch(:partials).size,
      data_model: @data_mode,
      origin: "Fleur-derived synthetic patterns; not the complete theme",
      source_commit: "f8edd032a5f74f02e359e6c7ad5b047c7bcc07e4",
      provenance: @fixture.fetch(:provenance),
      expected_sha256: Digest::SHA256.hexdigest(@fixture.fetch(:expected)),
      fixture_sha256: Digest::SHA256.hexdigest(JSON.generate(@fixture)),
      independent_oracle: true,
    }
  end

  private

  def prepare_assigns(raw)
    copy = Marshal.load(Marshal.dump(raw))
    return copy if @data_mode == "hash"

    copy.transform_values { |value| wrap(value) }
  end

  def wrap(value)
    case value
    when Hash then FleurRecordDrop.new(value.transform_values { |child| wrap(child) })
    when Array then value.map { |child| wrap(child) }
    else value
    end
  end

  def render_with(template, assigns, partials)
    template.render!(assigns, registers: {
      file_system: @filesystem, cached_partials: partials, cycle: {}, for: {},
    })
  end

  def assert_output(actual, expected)
    return if actual == expected

    offset = actual.bytes.zip(expected.bytes).index { |a, b| a != b }
    raise "#{@name}: independent HTML oracle mismatch at #{offset || actual.bytesize}; actual=#{actual.bytesize}, expected=#{expected.bytesize} bytes"
  end
end
