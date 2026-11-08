# frozen_string_literal: true

module CompatibilityCollectionCases
  def test_where_exp_comparisons_and_boolean_chains
    register_collection_filters
    template = parse("{{ rows | where_exp: 'row', expression | map: 'id' | join: ',' }}|{{ row }}")
    context = collection_context
    {
      "row.score >= 2" => "b,c",
      "row.score < 3 and row.enabled" => "a",
      "row.enabled or row.score > 1" => "a,b,c",
      "row.score > 1 and row.enabled or row.score == 1" => "c",
      "row.score == 1 or row.enabled and row.score > 2" => "a,c",
      "row.score != 2" => "a,c",
    }.each do |expression, expected|
      context["expression"] = expression
      assert_equal("#{expected}|outside", template.render!(context))
      assert_equal("outside", context["row"])
    end
  end

  def test_where_exp_nested_properties_contains_and_dynamic_indices
    register_collection_filters
    template = parse("{{ rows | where_exp: 'row', expression | map: 'id' | join: ',' }}")
    context = collection_context
    {
      "row.meta.type == 'keep'" => "a,c",
      "row.tags contains 'x'" => "a,c",
      "row contains 'score'" => "a,b,c",
      "row.tags[0] == 'x'" => "a",
      "row.tags[index] == wanted" => "c",
    }.each do |expression, expected|
      context["expression"] = expression
      assert_equal(expected, template.render!(context))
    end
  end

  def test_where_exp_false_nil_empty_and_numeric_values
    register_collection_filters
    rows = [false, nil, "", 0, 1]
    template = parse("{{ rows | where_exp: 'row', expression | json }}")
    context = collection_context("rows" => rows)
    {
      "row" => '["",0,1]',
      "row == false" => "[false]",
      "row == nil" => "[null]",
      "row == ''" => '[""]',
      "row == 0" => "[0]",
    }.each do |expression, expected|
      context["expression"] = expression
      assert_equal(expected, template.render!(context))
    end
  end

  def test_where_exp_hash_values_scalar_passthrough_and_repeated_bindings
    register_collection_filters
    template = parse("{{ rows | where_exp: 'row', 'row.score >= 2' | map: 'id' | join: ',' }}|" \
      "{{ rows | where_exp: 'row', 'row.score == 1' | map: 'id' | join: ',' }}|{{ row }}")
    context = collection_context("rows" => collection_rows.to_h { |row| [row["id"], row] })
    2.times { assert_equal("b,c|a|outside", template.render!(context)) }
    assert_equal("scalar", parse("{{ 'scalar' | where_exp: 'row', 'invalid expression' }}").render!)
  end

  def test_where_exp_short_circuit_avoids_failing_lookup
    register_collection_filters
    drop = Compatibility::Extensions::ExplosiveDrop.new
    context = collection_context("rows" => [drop])
    template = parse("{{ rows | where_exp: 'row', 'false and row.value' | size }}|" \
      "{{ rows | where_exp: 'row', 'true or row.value' | size }}")
    2.times { assert_equal("0|1", template.render!(context)) }
    assert_equal(0, drop.reads)
  end

  def test_where_exp_lookup_failure_restores_scope_and_allows_next_render
    register_collection_filters
    drop = Compatibility::Extensions::ExplosiveDrop.new
    context = collection_context("rows" => [drop], "expression" => "row.value")
    template = parse("{{ rows | where_exp: 'row', expression | size }}|{{ row }}")
    assert_raises(Liquid::ArgumentError) { template.render!(context) }
    assert_equal("outside", context["row"])
    assert_equal(1, drop.reads)
    context["rows"] = collection_rows
    context["expression"] = "row.score >= 2"
    assert_equal("2|outside", template.render!(context))
  end

  def test_where_exp_syntax_failure_reports_outer_line_and_recovers
    register_collection_filters
    @environment.exception_renderer = ->(error) { "ERR:#{error.class.name}:#{error.line_number}" }
    context = collection_context("expression" => "row.score ==")
    template = parse("До\n{{ rows | where_exp: 'row', expression | size }}|{{ row }}", line_numbers: true)
    assert_equal("До\nERR:Liquid::SyntaxError:2|outside", template.render(context))
    assert_equal(1, context.errors.size)
    assert_equal("outside", context["row"])
    context["expression"] = "row.score > 1"
    assert_equal("До\n2|outside", template.render(context))
  end

  def test_where_exp_drop_overrides_and_chained_selection
    register_collection_filters
    rows = collection_rows.map { |row| Compatibility::Extensions::MappingDrop.new(row) }
    rows[1]["enabled"] = true
    context = collection_context("rows" => rows)
    template = parse("{{ rows | where_exp: 'row', 'row.score >= 2' | " \
      "where_exp: 'row', 'row.enabled' | map: 'id' | join: ',' }}|{{ row }}")
    2.times { assert_equal("b,c|outside", template.render!(context)) }
  end

  def test_find_exp_returns_original_drop_and_stops_after_first_match
    register_collection_filters
    found = Compatibility::Extensions::MappingDrop.new("id" => "chosen", "score" => 3)
    failing = Compatibility::Extensions::ExplosiveDrop.new
    context = collection_context("rows" => [found, failing])
    variable = Liquid::Variable.new("rows | find_exp: 'row', 'row.score >= 2 or row.value'", Liquid::ParseContext.new)
    assert_same(found, variable.render(context))
    template = parse("{% assign found = rows | find_exp: 'row', 'row.score >= 2 or row.value' %}" \
      "{{ found.id }}|{{ row }}")
    2.times { assert_equal("chosen|outside", template.render!(context)) }
    assert_equal(0, failing.reads)
    assert_equal("[]", parse("[{{ rows | find_exp: 'row', 'row.score > 9' }}]").render!("rows" => collection_rows))
  end

  def test_group_by_exp_reuses_variable_with_filters_and_restores_binding
    register_collection_filters
    template = parse("{% assign groups = rows | group_by_exp: 'row', \"row.meta.type | upcase\" %}" \
      "{% for group in groups %}{{ group.name }}:{{ group.size }}=" \
      "{{ group.items | map: 'id' | join: ',' }};{% endfor %}|{{ row }}")
    context = collection_context
    2.times { assert_equal("KEEP:2=a,c;DROP:1=b;|outside", template.render!(context)) }
  end

  def test_group_by_exp_nested_expression_filter_preserves_outer_arguments
    register_collection_filters
    context = collection_context
    context["predicate"] = "child >= 2"
    context["grouping"] = "row.values | where_exp: 'child', predicate | size"
    context["child"] = "outer-child"
    context["rows"] = [
      { "id" => "a", "values" => [1, 2, 3] },
      { "id" => "b", "values" => [0] },
      { "id" => "c", "values" => [2, 4] },
    ]
    template = parse("{% assign groups = rows | group_by_exp: 'row', grouping %}" \
      "{% for group in groups %}{{ group.name }}:{{ group.items | map: 'id' | join: ',' }};" \
      "{% endfor %}|{{ row }}|{{ child }}")
    2.times { assert_equal("2:a,c;0:b;|outside|outer-child", template.render!(context)) }
  end

  def test_group_by_exp_exception_restores_scope_and_reuses_template
    register_collection_filters
    context = collection_context("grouping" => "row.value", "rows" => [Compatibility::Extensions::ExplosiveDrop.new])
    template = parse("{{ rows | group_by_exp: 'row', grouping | size }}|{{ row }}")
    assert_raises(Liquid::ArgumentError) { template.render!(context) }
    assert_equal("outside", context["row"])
    context["rows"] = collection_rows
    context["grouping"] = "row.meta.type"
    assert_equal("2|outside", template.render!(context))
  end

  def test_where_override_handles_arrays_nil_and_cached_repeated_calls
    register_collection_filters
    context = collection_context
    template = parse("{{ rows | where: 'tags', 'x' | map: 'id' | join: ',' }}|" \
      "{{ rows | where: 'score', '2' | map: 'id' | join: ',' }}|" \
      "{{ rows | where: 'missing', nil | size }}")
    2.times { assert_equal("a,c|b|3", template.render!(context)) }
    other = collection_context("rows" => [{ "id" => "z", "tags" => ["x"], "score" => 2 }])
    assert_equal("z|z|1", template.render!(other))
  end

  def test_where_override_registered_after_compilation_changes_semantics
    template = parse("{{ rows | where: 'tags', 'x' | map: 'id' | join: ',' }}")
    context = collection_context
    assert_equal("", template.render!(context))
    register_collection_filters
    2.times { assert_equal("a,c", template.render!(context)) }
  end

  def test_mapping_drop_root_payload_observes_mutations_and_lazy_values
    calls = 0
    lazy_value = lambda do
      calls += 1
      "computed"
    end
    payload = Compatibility::Extensions::MappingDrop.new(
      "off" => false, "empty" => "", "lazy" => lazy_value,
    )
    context = build_context(payload)
    template = parse("{{ title }}|{{ off }}:[{{ empty }}]|{{ lazy }}:{{ lazy }}")
    assert_equal("method-title|false:[]|computed:computed", template.render!(context))
    assert_equal(1, calls)
    payload["title"] = "overridden"
    payload["off"] = true
    assert_equal("overridden|true:[]|computed:computed", template.render!(context))
    assert_equal(1, calls)
  end

  def test_mapping_drop_strict_lookup_distinguishes_missing_and_defined_nil
    payload = Compatibility::Extensions::MappingDrop.new("present" => nil, "off" => false)
    context = build_context({ "payload" => payload })
    context.strict_variables = true
    assert_equal("[]|false", parse("[{{ payload.present }}]|{{ payload.off }}").render!(context))
    assert_raises(Liquid::UndefinedVariable) { parse("{{ payload.missing }}").render!(context) }
    payload["missing"] = "added"
    assert_equal("added", parse("{{ payload.missing }}").render!(context))
  end

  def test_mapping_drop_iterates_pairs_without_losing_false_or_nil
    payload = Compatibility::Extensions::MappingDrop.new("a" => 1, "b" => false, "c" => nil)
    template = parse("{% for pair in payload %}{{ pair[0] }}=[{{ pair[1] }}];{% endfor %}")
    assert_equal("a=[1];b=[false];c=[];", template.render!("payload" => payload))
  end

  def test_cached_fragment_nested_parameters_and_scopes
    context = build_context({ "name" => "outer", "label" => "one", "fragment" => { "label" => "outside" } })
    context.registers[:fragment_sources] = {
      "outer" => "O{{ fragment.label }}{% cached_fragment 'inner' %}Q",
      "inner" => "I{{ fragment.label }}{% assign hidden = 'inside' %}",
    }
    template = parse("A{% cached_fragment name %}|{{ fragment.label }}|{{ hidden }}Z")
    assert_equal("AOoneIoneQ|outside|insideZ", template.render!(context))
    cached = context.registers.fetch(:fragment_templates).dup
    context["label"] = "two"
    assert_equal("AOtwoItwoQ|outside|insideZ", template.render!(context))
    assert_equal("inside", context["hidden"])
    assert_equal(["inner", "outer"], cached.keys.sort)
    cached.each do |name, partial|
      assert_same(partial, context.registers[:fragment_templates][name])
      assert_equal(template.root.body.class, partial.root.body.class)
    end
  end

  def test_cached_fragment_error_keeps_filename_and_restores_outer_scope
    context = build_context({ "name" => "piece", "fail" => true, "fragment" => { "label" => "outside" } })
    context.registers[:fragment_sources] = { "piece" => "Внутри\n{{ 'argument' | fail_with }}" }
    template = parse("A{% cached_fragment name %}Z")
    error = assert_raises(Liquid::ArgumentError) { template.render!(context) }
    assert_equal("piece", error.template_name)
    assert_equal("nested ", error.markup_context)
    assert_equal(2, error.line_number)
    assert_equal("outside", context["fragment.label"])
    context["fail"] = false
    assert_equal("AВнутри\nargumentZ", template.render!(context))
    assert_equal("outside", context["fragment.label"])
  end

  def test_cached_template_instance_assigns_can_be_cleared_between_payloads
    template = parse("{{ saved }}|{% assign saved = title %}{{ saved }}")
    assert_equal("|first", template.render!("title" => "first"))
    assert_equal("first|second", template.render!("title" => "second"))
    template.instance_assigns.clear
    assert_equal("|third", template.render!("title" => "third"))
  end

  private

  def register_collection_filters
    @environment.register_filter(Compatibility::Extensions::CollectionFilters)
  end

  def collection_rows
    [
      { "id" => "a", "score" => 1, "enabled" => true, "tags" => ["x", "y"], "meta" => { "type" => "keep" } },
      { "id" => "b", "score" => 2, "enabled" => false, "tags" => ["y"], "meta" => { "type" => "drop" } },
      { "id" => "c", "score" => 3, "enabled" => true, "tags" => ["y", "x"], "meta" => { "type" => "keep" } },
    ]
  end

  def collection_context(assigns = {})
    build_context({ "rows" => collection_rows, "row" => "outside", "index" => 1, "wanted" => "x" }.merge(assigns))
  end
end
