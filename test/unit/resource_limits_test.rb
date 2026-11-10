# frozen_string_literal: true

require "test_helper"

class ResourceLimitsTest < Minitest::Test
  def test_subclass_preserves_overridden_limit_check
    subclass = Class.new(Liquid::ResourceLimits) do
      def increment_render_score(amount)
        super(amount * 2)
      end
    end
    original_enabled = Liquid::C.enabled

    [false, true].each do |enabled|
      Liquid::C.enabled = enabled
      limits = subclass.new(render_score_limit: 5)

      assert_instance_of(subclass, limits)
      limits.increment_render_score(2)
      assert_equal(4, limits.render_score)
      assert_raises(Liquid::MemoryError) { limits.increment_render_score(1) }
    end
  ensure
    Liquid::C.enabled = original_enabled
  end

  def test_base_class_uses_native_limits_when_enabled
    assert_instance_of(Liquid::C::ResourceLimits, Liquid::ResourceLimits.new({}))
  end

  def test_marshal_keeps_legacy_inactive_capture_marker
    limits = Liquid::ResourceLimits.new({})
    state = limits.marshal_dump
    assert_equal(-1, state.fetch(10))
    copy = Liquid::C::ResourceLimits.allocate
    copy.marshal_load(state)
    assert_equal(state, copy.marshal_dump)
  end

  def test_copy_preserves_state_and_is_independent
    original = Liquid::ResourceLimits.new(render_score_limit: 2**100, assign_score_limit: 5)
    original.increment_render_score(3)
    assert_raises(Liquid::MemoryError) { original.increment_assign_score(6) }
    [original.dup, original.clone].each do |copy|
      assert_equal(original.marshal_dump, copy.marshal_dump)
      copy.reset
      copy.increment_render_score(7)
      assert_equal(7, copy.render_score)
      assert_equal(3, original.render_score)
      assert_predicate(original, :reached?)
    end
    capture_limits = Liquid::ResourceLimits.new({})
    capture_limits.with_capture do
      capture_limits.increment_write_score("a")
      copy = capture_limits.dup
      copy.assign_score_limit = nil
      previous = copy.assign_score
      copy.increment_write_score("abc")
      assert_equal(previous + 2, copy.assign_score)
    end
  end

  def test_marshal_rejects_invalid_state_without_changing_limits
    limits = Liquid::ResourceLimits.new(render_score_limit: 5)
    limits.increment_render_score(3)
    original = limits.marshal_dump
    [9, 10].each do |index|
      state = original.dup
      state[index] = "invalid"
      assert_raises(TypeError) { limits.marshal_load(state) }
      assert_equal(original, limits.marshal_dump)
    end
    [[], original + [nil]].each do |state|
      assert_raises(ArgumentError) { limits.marshal_load(state) }
      assert_equal(original, limits.marshal_dump)
    end
    assert_raises(TypeError) { limits.marshal_load(nil) }
    assert_equal(original, limits.marshal_dump)
    state = original.dup
    state[10] = 2**100
    limits.marshal_load(state)
    assert_equal(state, limits.marshal_dump)
  end

  def test_marshal_load_preserves_frozen_state
    limits = Liquid::ResourceLimits.new(render_score_limit: 5)
    state = limits.marshal_dump
    limits.freeze
    assert_raises(FrozenError) { limits.marshal_load(state) }
    assert_equal(state, limits.marshal_dump)
  end

  def test_increment_render_score
    resource_limits = Liquid::ResourceLimits.new(render_score_limit: 5)
    resource_limits.increment_render_score(4)
    assert_raises(Liquid::MemoryError) do
      resource_limits.increment_render_score(2)
    end
    assert_equal(6, resource_limits.render_score)
  end

  def test_increment_assign_score
    resource_limits = Liquid::ResourceLimits.new(assign_score_limit: 5)
    resource_limits.increment_assign_score(5)
    assert_raises(Liquid::MemoryError) do
      resource_limits.increment_assign_score(1)
    end
    assert_equal(6, resource_limits.assign_score)
  end

  def test_increment_write_score
    resource_limits = Liquid::ResourceLimits.new(render_length_limit: 5)
    output = "a" * 10
    assert_raises(Liquid::MemoryError) do
      resource_limits.increment_write_score(output)
    end
  end

  def test_raise_limits_reached
    resource_limits = Liquid::ResourceLimits.new({})
    assert_raises(Liquid::MemoryError) do
      resource_limits.raise_limits_reached
    end
    assert(resource_limits.reached?)
  end

  def test_with_capture
    resource_limits = Liquid::ResourceLimits.new(assign_score_limit: 5)
    output = "foo"

    resource_limits.with_capture do
      resource_limits.increment_write_score(output)
    end

    assert_equal(3, resource_limits.assign_score)
  end
end
