# frozen_string_literal: true

module Compatibility
  module Scenarios
    class << self
      def curated
        cases = []
        expressions = [
          "x",
          "x.first",
          "x.last",
          "x.size",
          'x["first"]',
          'x["a.b"]',
          "x[0]",
          "x[-1]",
          "x[key]",
          "self.x",
          'self["x"]',
          "[key]",
          "blank",
          "empty",
          "nil",
          "null",
          "true",
          "false",
          "-",
          "-0.5",
          "0.5.6",
          "1.",
          ".5",
          "123.foo",
          "x . size",
          "x[",
          "x..y",
          "x\0y",
        ]
        values = {
          string: "éЖ",
          empty_string: "",
          array: ["a", nil, "b"],
          hash: { "first" => false, "a.b" => "literal" },
        }
        expressions.each_with_index do |expression, index|
          values.each do |kind, value|
            cases << {
              id: "expression_#{index}_#{kind}",
              source: "{{ #{expression} }}",
              assigns: { "x" => value, "key" => "x" },
            }
          end
        end
        [" ", "\t ", "\n\t", "\r\n", "\v\f", "\u00a0"].each_with_index do |whitespace, index|
          [false, true].each do |legacy|
            cases << {
              id: "trim_#{index}_#{legacy}",
              source: "{% if true %}left{% endif %}#{whitespace}{{- '' -}} right",
              options: { bug_compatible_whitespace_trimming: legacy },
            }
          end
        end
        ["\xC0", "\xE0\x01", "\xE0", "\xF0\x01\x01", "\xF0\x01", "\xF0", "\xFF"].each_with_index do |bytes, index|
          cases << { id: "encoding_#{index}", source: "A\n{{ #{bytes} }}Z" }
        end
        sources = {
          quoted_delimiter: '{{ "}}" }}',
          quoted_tag_delimiter: '{% assign x = "%}" %}{{ x }}',
          trailing_filter_comma: '{{ "x" | append: "y", }}',
          empty_filter_argument: '{{ "x" | upcase: }}',
          filter_kwarg: '{{ "x" | probe: "y", label: "z" }}',
          unknown_filter: '{{ "x" | absent }}',
          ruby_filter_error: "A\n{{ 1 | ruby_explode }}Z",
          liquid_filter_error: "A\n{{ 1 | explode }}Z",
          error_in_assign: "A{% assign x = 1 | explode %}Z",
          error_in_capture: "A{% capture x %}{{ 1 | explode }}{% endcapture %}{{ x }}Z",
          malformed_if: "{% if %}x{% endif %}",
          malformed_for: "{% for x (1..2) %}{{ x }}{% endfor %}",
          unclosed_block: "{% if true %}x",
          mismatched_end: "{% for x in (1..2) %}{% endif %}",
          top_level_break: "A{% break %}Z",
          top_level_continue: "A{% continue %}Z",
          case_after_else: "{% case x %}{% else %}a{% when 1 %}b{% endcase %}",
          case_multiple_else: "{% case x %}{% else %}a{% else %}b{% endcase %}",
          case_fallthrough: "{% case x %}{% when 1 %}a{% when 1 %}b{% else %}c{% endcase %}",
          nested_control: "{% for i in (1..3) %}{% if i == 2 %}{% continue %}{% endif %}" \
            "{% case i %}{% when 3 %}{% break %}{% else %}{{ i }}{% endcase %}{% endfor %}",
          tablerow: "{% tablerow i in (1..3) cols: 2 %}{{ tablerowloop.index }}:{{ i }}{% endtablerow %}",
          range_score: "{% for i in (1..1000000000) offset: 1 limit: 2 %}{{ i }}{% endfor %}",
          raw_delimiter: "{% raw %}a{% endraw extra %}b",
          raw_substring: "{% raw %}a{% endrawx %}b{% endraw %}",
          raw_no_spaces: "{%raw%}a{%endraw%}",
          doc_body: "A{% doc %}{{ x }}{% if broken %}{% enddoc %}Z",
          custom_block: "A{% buffer %}{% marker %}{{ x }}{% endbuffer %}Z",
          proc_lookup: "{{ x }}|{{ x }}",
          nested_arrays: "{{ x }}",
          self_reuse: "{{ self.title }}",
        }
        sources.each do |id, source|
          cases << { id: id.to_s, source: source, assigns: { "x" => 1, "title" => "T" } }
        end
        [
          "safe",
          "unsafe",
          "cache",
          "cache_disabled",
          "limits",
          "cumulative_render",
          "cumulative_assign",
          "render_reset",
          "assign_reset",
          "context_drop",
          "drop_index",
          "drop_key",
          "drop_false",
          "drop_comparison",
          "static_environment",
          "filter_reload",
          "registers",
          "include",
          "render_isolation",
          "binary_buffer",
          "profile",
          "visit",
          "marshal",
        ].each do |operation|
          cases << { id: "api_#{operation}", operation: operation }
        end
        cases
      end

      def generated
        seed = Integer(ENV.fetch("GENERATOR_SEED", "51400"))
        random = Random.new(seed)
        count = Integer(ENV.fetch("GENERATOR_COUNT", "256"))
        atoms = ["x", "x.first", "x.last", "x.size", "x[key]", "self.x", "[key]", "nil", "false", "0", "-0.5", '"é"']
        filters = [
          "",
          " | default: 'D'",
          " | size",
          " | first",
          " | last",
          " | append: '!'",
          " | probe: '?', label: 'L'",
          " | wrapped",
        ]
        values = [nil, false, 0, "", "éЖ", [], [1, nil, "a"], { "a" => "b", "first" => "key" }]
        Array.new(count) do |index|
          expression = atoms.sample(random: random) + filters.sample(random: random)
          variable = "{{ #{expression} }}"
          source = case random.rand(6)
          when 0 then variable
          when 1 then "A{% capture result %}#{variable}{% endcapture %}[{{ result }}]Z"
          when 2 then "{% assign result = #{expression} %}{{ result }}"
          when 3 then "{% if x %}#{variable}{% else %}empty{% endif %}"
          when 4 then "{% for i in (1..3) limit: 2 %}#{variable}{{ i }}{% endfor %}"
          when 5 then "L {{- #{expression} -}} R"
          end
          {
            id: "seed_#{seed}_#{index}",
            source: source,
            assigns: { "x" => values.sample(random: random), "key" => "a" },
          }
        end
      end
    end
  end
end
