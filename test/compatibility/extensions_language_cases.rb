# frozen_string_literal: true

module CompatibilityLanguageCases
  def test_expression_parse_patch_returns_runtime_objects_in_compiled_variables
    with_patch(Liquid::Expression.singleton_class, Compatibility::Extensions::ExtraExpressions) do
      context = build_context({ "runtime_value" => "first" })
      template = parse("{{ runtime_literal | append: '!' }}|{% assign result = runtime_literal %}{{ result }}")
      assert_equal("first!|first", template.render!(context))
      context["runtime_value"] = "second"
      assert_equal("second!|second", template.render!(context))
      assert_equal(4, context.registers[:expression_calls])
    end
  end

  def test_expression_parse_patch_applies_to_arguments_and_conditions
    with_patch(Liquid::Expression.singleton_class, Compatibility::Extensions::ExtraExpressions) do
      context = build_context({ "runtime_value" => 3 })
      template = parse("{{ 'v' | append: runtime_literal }}|{% if runtime_literal > 2 %}yes{% endif %}")
      2.times { assert_equal("v3|yes", template.render!(context)) }
      assert_equal(4, context.registers[:expression_calls])
    end
  end

  def test_expression_patch_does_not_change_previously_parsed_lookups
    original = parse("{{ runtime_literal }}")
    patched = nil
    with_patch(Liquid::Expression.singleton_class, Compatibility::Extensions::ExtraExpressions) do
      patched = parse("{{ runtime_literal }}")
      values = { "runtime_literal" => "lookup", "runtime_value" => "expression" }
      assert_equal("lookup", original.render!(values))
      assert_equal("expression", patched.render!(values))
    end
    assert_equal("stored", patched.render!("runtime_value" => "stored"))
    assert_equal("lookup", parse("{{ runtime_literal }}").render!("runtime_literal" => "lookup"))
  end

  def test_runtime_expression_failure_does_not_corrupt_following_render
    with_patch(Liquid::Expression.singleton_class, Compatibility::Extensions::ExtraExpressions) do
      context = build_context({ "runtime_value" => "ok", "expression_failure" => true })
      template = parse("A{{ runtime_literal | append: '!' }}Z")
      assert_raises(Liquid::ArgumentError) { template.render!(context) }
      context["expression_failure"] = false
      assert_equal("Aok!Z", template.render!(context))
      assert_equal(2, context.registers[:expression_calls])
    end
  end

  def test_expression_patch_adds_method_literal_to_standard_condition
    with_patch(Liquid::Expression.singleton_class, Compatibility::Extensions::ExtraExpressions) do
      template = parse("{% if value == filled_literal %}filled{% else %}empty{% endif %}")
      [nil, false, "", "text", 0].each do |value|
        drop = Compatibility::Extensions::SemanticDrop.new(value)
        expected = [nil, false, ""].include?(value) ? "empty" : "filled"
        assert_equal(expected, template.render!("value" => drop))
      end
    end
  end

  def test_custom_condition_operator_respects_parser_mode
    with_condition_operator("starts_with", ->(_condition, left, right) { left.to_s.start_with?(right.to_s) }) do
      source = "{% if title starts_with 'ab' %}yes{% else %}no{% endif %}"
      if [:lax, :warn].include?(Compatibility::MODE)
        template = parse(source)
        assert_equal("yes", template.render!("title" => "abc"))
        assert_equal("no", template.render!("title" => "xyz"))
      else
        assert_raises(Liquid::SyntaxError) { parse(source) }
      end
    end
  end

  def test_condition_operator_can_be_replaced_after_compilation
    template = parse("{% if title contains needle %}yes{% else %}no{% endif %}")
    values = { "title" => "abc", "needle" => "b" }
    assert_equal("yes", template.render!(values))
    with_condition_operator("contains", ->(_condition, left, right) { left.to_s.end_with?(right.to_s) }) do
      2.times { assert_equal("no", template.render!(values)) }
    end
    assert_equal("yes", template.render!(values))
  end

  def test_component_block_collects_regions_and_builds_render_tag_at_runtime
    @environment.file_system = Compatibility::FileSystem.new(
      "card" => "[{{ content }}|{{ footer }}]{% assign hidden = 'inside' %}",
    )
    template = parse("{% component 'card' %}Hello {{ title }}" \
      "{% region footer %}Foot {{ title }}{% endregion %}{% endcomponent %}|" \
      "{{ region_footer }}:{{ component_content }}:{{ hidden }}")
    context = build_context({ "title" => "one" })
    assert_equal("[<p>Hello one</p>|Foot one]|::", template.render!(context))
    context["title"] = "two"
    assert_equal("[<p>Hello two</p>|Foot two]|::", template.render!(context))
    assert_equal(["card"], @environment.file_system.reads)
  end

  def test_parent_body_drop_reenters_render_from_variable_filter_chain
    parent = parse("P{{ title | append: marker }}Q")
    context = build_context({ "title" => "one", "marker" => "!", "suffix" => "?" })
    context["parent"] = Compatibility::Extensions::ParentBodyDrop.new(parent)
    child = parse("A{{ parent.super | append: suffix }}Z")
    assert_equal("APone!Q?Z", child.render!(context))
    context["title"] = "two"
    assert_equal("APtwo!Q?Z", child.render!(context))
  end

  def test_lazy_collection_observes_scope_during_iteration
    drop = Compatibility::Extensions::ScopedCollectionDrop.new(["a", "b", "c"])
    context = build_context({ "items" => drop })
    template = parse("{% selection %}{% for item in items %}{{ item }}{% endfor %}{% endselection %}|" \
      "{% for item in items %}{{ item }}{% endfor %}")
    2.times { assert_equal("b|abc", template.render!(context)) }
    assert_nil(context["selection"])
  end

  private

  def with_condition_operator(name, implementation)
    operators = Liquid::Condition.operators
    existed = operators.key?(name)
    original = operators[name]
    operators[name] = implementation
    yield
  ensure
    existed ? operators[name] = original : operators.delete(name)
  end
end
