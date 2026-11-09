# frozen_string_literal: true

require "json"

def benchmark_fixtures
  fixtures = JSON.parse(File.read(File.join(__dir__, "fixtures.json"))).fetch("scenarios")
  fixtures.push(
    { "id" => "text/small", "source" => "plain " * 80, "assigns" => {}, "partials" => {}, "expected" => "plain " * 80 },
    {
      "id" => "text/large",
      "source" => "plain " * 20_000,
      "assigns" => {},
      "partials" => {},
      "expected" => "plain " * 20_000,
    },
    {
      "id" => "unique/large",
      "source" => (0...384).map { |i| "{{ value#{i} }}" }.join,
      "assigns" => (0...384).to_h { |i| ["value#{i}", i] },
      "partials" => {},
      "expected" => (0...384).to_a.join,
    },
    {
      "id" => "condition_headers/large",
      "source" => "{% if value > 1 and value < 4 %}x{% endif %}" * 96,
      "assigns" => { "value" => 2 },
      "partials" => {},
      "expected" => "x" * 96,
    },
    {
      "id" => "for_headers/large",
      "source" => "{% for i in values reversed limit: 1 %}{{ i }}{% endfor %}" * 96,
      "assigns" => { "values" => [1, 2, 3] },
      "partials" => {},
      "expected" => "1" * 96,
    },
    {
      "id" => "case_headers/large",
      "source" => "{% case value %}{% when 2 %}x{% else %}y{% endcase %}" * 96,
      "assigns" => { "value" => 2 },
      "partials" => {},
      "expected" => "x" * 96,
    },
  )
  case_assigns = (0...96).to_h do |index|
    value = { "value" => 2 }
    40.times { value = { "child" => value } }
    ["product#{index}", value]
  end
  fixtures << {
    "id" => "case_deep/large",
    "source" => (0...96).map do |index|
      "{% case product#{index}#{".child" * 40}.value %}{% when 2 %}x{% else %}y{% endcase %}"
    end.join,
    "assigns" => case_assigns,
    "partials" => {},
    "expected" => "x" * 96,
  }
  condition_assigns = (0...96).to_h do |index|
    value = { "value" => 2 }
    40.times { value = { "child" => value } }
    ["product#{index}", value]
  end
  fixtures << {
    "id" => "condition_deep/large",
    "source" => (0...96).map do |index|
      "{% if product#{index}#{".child" * 40}.value == 2 %}x{% endif %}"
    end.join,
    "assigns" => condition_assigns,
    "partials" => {},
    "expected" => "x" * 96,
  }
  for_assigns = (0...96).to_h do |index|
    value = { "values" => [1] }
    40.times { value = { "child" => value } }
    ["product#{index}", value]
  end
  fixtures << {
    "id" => "for_deep/large",
    "source" => (0...96).map do |index|
      "{% for i in product#{index}#{".child" * 40}.values %}{{ i }}{% endfor %}"
    end.join,
    "assigns" => for_assigns,
    "partials" => {},
    "expected" => "1" * 96,
  }
  deep_assigns = (0...16).to_h do |index|
    value = "ok"
    256.times { value = { "child" => value } }
    ["product#{index}", value]
  end
  fixtures << {
    "id" => "expression_deep/large",
    "source" => (0...16).map { |index| "{{ product#{index}#{".child" * 256} }}" }.join,
    "assigns" => deep_assigns,
    "partials" => {},
    "expected" => "ok" * 16,
  }
  fixtures
end
