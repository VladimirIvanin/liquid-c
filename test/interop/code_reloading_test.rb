# frozen_string_literal: true

require_relative "interop_helper"

# Code reloading (Zeitwerk, Rails development mode) redefines drop and tag
# classes between a parse and a later render.
class CodeReloadingTest < Minitest::Test
  include InteropHelper

  def test_redefined_drop_method_is_used_by_an_existing_template
    drop_class = Class.new(Liquid::Drop) do
      def name
        "before"
      end
    end
    template = Liquid::Template.parse("{{ drop.name }}")
    assert_equal("before", template.render!({ "drop" => drop_class.new }))

    drop_class.class_eval do
      def name
        "after"
      end
    end
    assert_equal("after", template.render!({ "drop" => drop_class.new }))
  end

  def test_replaced_tag_class_is_used_by_new_parses_only
    first = Class.new(Liquid::Tag) do
      def render(_context)
        "first"
      end
    end
    second = Class.new(Liquid::Tag) do
      def render(_context)
        "second"
      end
    end
    environment = Liquid::Environment.build { |env| env.register_tag("reloaded", first) }
    old_template = Liquid::Template.parse("{% reloaded %}", environment: environment)

    environment = Liquid::Environment.build { |env| env.register_tag("reloaded", second) }
    new_template = Liquid::Template.parse("{% reloaded %}", environment: environment)

    assert_equal("first", old_template.render!)
    assert_equal("second", new_template.render!)
    GC.start
    compact_fragmented_heap(rounds: 1)
    assert_equal("first", old_template.render!)
    assert_equal("second", new_template.render!)
  end
end
