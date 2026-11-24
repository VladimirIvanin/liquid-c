# frozen_string_literal: true

require "test_helper"
require "objspace"

# Situations in which another gem or the Ruby runtime moves, interleaves or
# inspects objects while Liquid C holds native state. Each scenario is named
# after the gem or runtime feature that creates it.
module InteropHelper
  NATIVE_CLASSES = [
    -> { Liquid::Raw },
    -> { Liquid::C::Expression },
    -> { Liquid::C::BlockBody },
    -> { Liquid::C::Tokenizer },
    -> { Liquid::C::ResourceLimits },
    -> { Liquid::Variable },
    -> { Liquid::VariableLookup },
    -> { Liquid::RangeLookup },
  ].freeze

  SOURCE = <<~LIQUID
    {% raw %}{{ literal }}{% endraw %}
    {% assign total = 0 %}
    {% for item in items %}{% assign total = total | plus: item.price %}{{ item.name | upcase }}:{{ item.price }},{% endfor %}
    {% for n in (1..3) %}{{ n }}{% endfor %}
    total={{ total }}
  LIQUID

  ASSIGNS = {
    "items" => [{ "name" => "a", "price" => 2 }, { "name" => "b", "price" => 3 }],
  }.freeze

  def expected_output
    @expected_output ||= Liquid::Template.parse(SOURCE, disable_liquid_c_nodes: true).render!(ASSIGNS)
  end

  def render_source(source = SOURCE, assigns = ASSIGNS, **options)
    Liquid::Template.parse(source).render!(assigns, **options)
  end

  # Compacts a fragmented heap so that unpinned objects, including classes,
  # are really moved. Returns true when the platform supports compaction.
  def compact_fragmented_heap(rounds: 2)
    return false unless GC.respond_to?(:verify_compaction_references)
    # Repeated compaction crashes MRI 3.2 itself (reproducible without any gems).
    return false if RUBY_VERSION < "3.3"

    rounds.times do
      garbage = Array.new(30_000) { Object.new }
      garbage = garbage.each_slice(2).map(&:first)
      GC.start
      GC.verify_compaction_references(expand_heap: true, toward: :empty)
      garbage.clear
    end
    true
  rescue NotImplementedError
    false
  end

  def address_of(object)
    ObjectSpace.dump(object)[/"address":"(0x\h+)"/, 1]
  end

  def native_class_addresses
    NATIVE_CLASSES.map { |lookup| address_of(lookup.call) }
  end

  # Exercises every native entry point that stores a class or object.
  def assert_native_paths_work
    assert_equal(expected_output, render_source)
    assert_kind_of(Liquid::C::Expression, Liquid::C::Expression.strict_parse("items[0].name"))
    assert_equal("a", Liquid::C::Expression.strict_parse("items[0].name").evaluate(Liquid::Context.new(ASSIGNS.dup)))
    assert_equal(
      "{{ literal }}",
      Liquid::Template.parse("{% raw %}{{ literal }}{% endraw %}").render!,
    )
    assert_equal("123", render_source("{% for n in (1..3) %}{{ n }}{% endfor %}", {}))
  end
end
