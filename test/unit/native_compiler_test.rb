# frozen_string_literal: true

require_relative "../test_helper"
require "open3"
require "rbconfig"

class NativeCompilerTest < Minitest::Test
  def test_capture_warn_skips_the_ruby_header_parser_and_keeps_whitespace
    skip("direct compiler is unavailable") unless Liquid::C::NativeParser::NATIVE_GUARDS

    isolated(<<~'RUBY')
      GC.start
      GC.disable
      before = ObjectSpace.each_object(Liquid::Parser).count
      template = parse("{% capture result %}  {{ value }}\n {% capture inner %} inside {% endcapture %}{{ inner }}{% endcapture %}{{ result }}")
      check(before, ObjectSpace.each_object(Liquid::Parser).count)
      check("  yes\n  inside ", template.render!("value" => "yes"))
      capture = template.root.nodelist.first
      check(Liquid::Capture, capture.class)
      check("result", capture.to)
      check(true, capture.blank?)
      check(true, capture.instance_variable_get(:@body).frozen?)
      check([], template.warnings)
    RUBY
  end

  def test_capture_falls_back_for_invalid_headers_and_other_modes
    isolated(<<~'RUBY')
      ["name extra", "", "contains", "name?", "a.b", "123", " name\0"].each do |header|
        source = "first\n{% capture #{header} %} text {% endcapture %}"
        [:lax, :warn, :strict, :strict2].each do |mode|
          observe = lambda do |disabled|
            template = parse(source, error_mode: mode, disable_liquid_c_nodes: disabled)
            node = template.root.nodelist.last
            [template.render, node.to, template.warnings.map { |e| [e.class, e.message, e.line_number] }]
          rescue Liquid::Error => error
            [error.class, error.message, error.line_number]
          end
          check(observe.call(true), observe.call(false))
        end
      end
    RUBY
  end

  def test_capture_observes_header_and_block_hooks
    isolated(<<~'RUBY')
      [:initialize, :strict2_parse, :parse, :new_body, :parse_body, :block_delimiter, :blank?].each do |name|
        original = Liquid::Capture.instance_method(name)
        calls = 0
        Liquid::Capture.define_method(name) do |*args, &block|
          calls += 1
          original.bind_call(self, *args, &block)
        end
        check(" yes ", parse("{% capture c %} yes {% endcapture %}{{ c }}").render!)
        raise "capture hook bypassed: #{name}" if calls.zero?
        Liquid::Capture.send(:remove_method, name)
        Liquid::Capture.define_method(name, original) if original.owner == Liquid::Capture
      end
    RUBY
  end

  def test_capture_continues_after_a_nested_ruby_tag_changes_hooks
    isolated(<<~RUBY)
      calls = []
      original = Liquid::Capture.instance_method(:block_delimiter)
      tag = Class.new(Liquid::Tag) do
        define_method(:initialize) do |*args|
          super(*args)
          Liquid::Capture.define_method(:block_delimiter) do
            calls << :delimiter
            original.bind_call(self)
          end
          GC.start
        end
      end
      Liquid::Environment.default.register_tag("change_capture", tag)
      template = parse("{% capture c %}before{% change_capture %}after{% endcapture %}{{ c }}")
      check("beforeafter", template.render!)
      raise "new delimiter hook bypassed" if calls.empty?
    RUBY
  end

  def test_capture_errors_restore_depth_and_allow_another_parse
    isolated(<<~RUBY)
      ["{% capture c %}", "{% capture c %}{% else %}{% endcapture %}",
        "{% capture c %}{% endother %}", "{% capture c %}" * 101 + "{% endcapture %}" * 101].each do |source|
        observe = lambda do |disabled|
          context = Liquid::ParseContext.new(error_mode: :warn, line_numbers: true, disable_liquid_c_nodes: disabled)
          begin
            Liquid::Template.parse(source, context)
          rescue Liquid::Error => error
            [error.class, error.message, error.line_number, context.depth]
          end
        end
        check(observe.call(true), observe.call(false))
        check("ok", parse("{% capture c %}ok{% endcapture %}{{ c }}").render!)
      end
    RUBY
  end

  def test_include_warn_skips_the_ruby_parser_and_preserves_cache_identity
    skip("direct compiler is unavailable") unless Liquid::C::NativeParser::NATIVE_GUARDS

    isolated(<<~RUBY)
      GC.start
      GC.disable
      before = ObjectSpace.each_object(Liquid::Parser).count
      template = parse("{% include names[key] for items as entry, x: items, x: other, flag: true %}")
      check(before, ObjectSpace.each_object(Liquid::Parser).count)
      tag = template.root.nodelist.first
      check(Liquid::Include, tag.class)
      check(true, tag.for_loop?)
      check("entry", tag.instance_variable_get(:@alias_name))
      check(["x", "flag"], tag.attributes.keys)
      cache = tag.send(:parse_context).instance_variable_get(:@expression_cache)
      check(["key", "names[key]", "items", "other"], cache.keys)
      raise "template cache identity lost" unless cache.fetch("names[key]").equal?(tag.template_name_expr)
      raise "variable cache identity lost" unless cache.fetch("items").equal?(tag.variable_name_expr)
      raise "attribute cache identity lost" unless cache.fetch("other").equal?(tag.attributes.fetch("x"))
      check([], template.warnings)
    RUBY
  end

  def test_include_headers_and_cache_match_the_ruby_path
    isolated(<<~'RUBY')
      headers = ["'item'", "'item',", "'item' with nil", "'item' with false as item", "name with obj as item, a: obj[key], b: (1..3), a: 2",
        "name for values", "name as alias", "name a: nil b: false, c: empty, d: 'a b'",
        "[key] with self.value", "names . first, n: 1.5", "'item',,", "'item' as contains",
        "'item' a:", "'item' with", "'item' extra", "'item' | upcase", "", "contains"]
      [:lax, :warn, :strict, :strict2].each do |mode|
        headers.each do |header|
          observe = lambda do |disabled|
            context = Liquid::ParseContext.new(error_mode: mode, disable_liquid_c_nodes: disabled, line_numbers: true)
            template = Liquid::Template.parse("first\n{% include #{header} %}", context)
            tag = template.root.nodelist.last
            snapshot = lambda do |value|
              case value
              when Liquid::VariableLookup then [:lookup, snapshot.call(value.name), value.lookups.map { |v| snapshot.call(v) }]
              when Liquid::RangeLookup then [:range, snapshot.call(value.start_obj), snapshot.call(value.end_obj)]
              when Range then [:range, value.begin, value.end]
              else value
              end
            end
            [snapshot.call(tag.template_name_expr), snapshot.call(tag.variable_name_expr), tag.for_loop?,
              tag.instance_variable_get(:@alias_name), tag.attributes.map { |k, v| [k, snapshot.call(v)] },
              tag.instance_variables.sort, context.instance_variable_get(:@expression_cache).keys,
              template.warnings.map { |e| [e.class, e.message, e.line_number] }]
          rescue Liquid::Error => error
            [error.class, error.message, error.line_number]
          end
          check(observe.call(true), observe.call(false))
        end
      end
    RUBY
  end

  def test_include_observes_parser_hooks_before_and_after_loading
    [false, true].each do |before_load|
      setup = <<~RUBY
        require "liquid"
        $include_calls = []
        Liquid::Include.prepend(Module.new do
          def strict2_parse(markup)
            $include_calls << markup
            super
          end
        end)
      RUBY
      body = <<~RUBY
        template = parse("{% include 'item' %}")
        check(["'item' "], $include_calls)
        check(Liquid::Include, template.root.nodelist.first.class)
      RUBY
      before_load ? isolated(body, before: setup) : isolated(setup + body)
    end
  end

  def test_include_runtime_disableable_and_partial_cache_are_preserved
    isolated(<<~RUBY)
      reads = []
      file_system = Object.new
      file_system.define_singleton_method(:read_template_file) do |name|
        reads << name
        "{{ entry }}:{{ x }};"
      end
      env = Liquid::Environment.build { |e| e.file_system = file_system }
      template = parse("{% capture c %}{% include 'item' for items as entry, x: 'X' %}{% endcapture %}{{ c }}", environment: env)
      registers = { file_system: file_system, cached_partials: {} }
      2.times do
        check("a:X;b:X;", template.render!({ "items" => ["a", "b"] }, registers: registers))
      end
      check(["item"], reads)
      context = Liquid::Context.build(environment: env)
      context.with_disabled_tags(["include"]) do
        begin
          template.render(context)
          raise "disabled include was rendered"
        rescue Liquid::DisabledError
          check(["item"], reads)
        end
      end
    RUBY
  end

  def test_capture_and_include_tracepoint_observes_the_original_constructors
    isolated(<<~RUBY)
      calls = []
      trace = TracePoint.new(:call) do |event|
        calls << event.defined_class if event.method_id == :initialize
      end
      template = trace.enable { parse("{% capture c %}{% include 'item' %}{% endcapture %}") }
      raise "capture constructor was hidden" unless calls.include?(Liquid::Capture)
      raise "include constructor was hidden" unless calls.include?(Liquid::Include)
      check(Liquid::Capture, template.root.nodelist.first.class)
    RUBY
  end

  def test_capture_and_include_constructor_and_parse_overrides_are_observed
    isolated(<<~'RUBY')
      [[Liquid::Capture, "{% capture c %}x{% endcapture %}"], [Liquid::Include, "{% include 'item' %}"]].each do |klass, source|
        [:new, :parse].each do |name|
          original = klass.method(name)
          calls = 0
          klass.define_singleton_method(name) do |*args|
            calls += 1
            original.call(*args)
          end
          parse(source)
          raise "constructor hook bypassed: #{klass}.#{name}" if calls.zero?
          klass.singleton_class.send(:remove_method, name)
        end
      end
    RUBY
  end

  def test_capture_constructor_hook_installed_before_loading_is_observed
    isolated(<<~RUBY, before: <<~BEFORE)
      check("ok", parse("{% capture c %}ok{% endcapture %}{{ c }}").render!)
      check(["capture"], $capture_calls)
    RUBY
      require "liquid"
      $capture_calls = []
      Liquid::Capture.prepend(Module.new do
        def initialize(*args)
          $capture_calls << args.first
          super
        end
      end)
    BEFORE
  end

  def test_capture_and_include_revalidate_after_same_size_cache_key_replacement
    isolated(<<~RUBY)
      tag = Class.new(Liquid::Tag) do
        define_method(:initialize) do |*args|
          super(*args)
          cache = parse_context.instance_variable_get(:@expression_cache)
          size = cache.size
          cache.delete("first")
          cache[:foreign] = 1
          raise "cache size changed" unless size == cache.size
        end
      end
      env = Liquid::Environment.build { |e| e.register_tag("replace_key", tag) }
      source = "{{ first }}{% replace_key %}{% capture c %}{{ second }}{% endcapture %}" \
        "{% include 'item', x: second %}"
      [true, false].each do |disabled|
        template = parse(source, environment: env, disable_liquid_c_nodes: disabled)
        include_tag = template.root.nodelist.last
        capture = template.root.nodelist.grep(Liquid::Capture).first
        raise "shared expression identity lost" unless include_tag.attributes.fetch("x").equal?(capture.nodelist.first.name)
      end
    RUBY
  end

  def test_inherited_expression_constructors_keep_native_tags_after_entry_refresh
    skip("direct compiler is unavailable") unless Liquid::C::NativeParser::NATIVE_GUARDS

    isolated(<<~RUBY)
      Class.class_eval do
        private :new
        public :new
      end
      [Liquid::VariableLookup, Liquid::RangeLookup, Liquid::Parser].each do |klass|
        klass.singleton_class.class_eval do
          alias_method :new, :new
          remove_method :new
        end
      end
      GC.start
      GC.compact if GC.respond_to?(:compact)
      GC.disable
      before = ObjectSpace.each_object(Liquid::Parser).count
      template = parse("{% capture c %}{{ item.name }}{% include 'item', x: item.name %}{% endcapture %}")
      check(before, ObjectSpace.each_object(Liquid::Parser).count)
      check(Liquid::Capture, template.root.nodelist.first.class)
    RUBY
  end

  def test_expression_constructor_overrides_still_disable_native_tags
    isolated(<<~'RUBY')
      [Liquid::VariableLookup, Liquid::Parser].each do |klass|
        original = klass.method(:new)
        calls = 0
        klass.define_singleton_method(:new) do |*args, **kwargs|
          calls += 1
          original.call(*args, **kwargs)
        end
        template = parse("{% capture c %}{{ item.name }}{% endcapture %}{{ c }}")
        check("ok", template.render!("item" => { "name" => "ok" }))
        raise "expression constructor override was bypassed: #{klass}" if calls.zero?
        klass.singleton_class.send(:remove_method, :new)
      end
    RUBY
  end

  def test_include_observes_false_equality_when_the_binding_is_absent
    isolated(<<~RUBY)
      original = FalseClass.instance_method(:==)
      calls = []
      FalseClass.define_method(:==) do |other|
        calls << other
        original.bind_call(self, other)
      end
      template = parse("{% include 'item' %}")
      raise "include equality hook bypassed" unless calls.include?("for")
      check(false, template.root.nodelist.first.for_loop?)
    RUBY
  end

  def test_renderer_hook_survives_compaction_and_restoration
    isolated(<<~RUBY)
      original = Liquid::Variable.instance_method(:render)
      Liquid::Variable.define_method(:render) do |context|
        original.bind_call(self, context).to_s + "!"
      end
      source = "{{ value }}{% if value %}{{ value }}{% endif %}"
      check("first!first!", parse(source).render!("value" => "first"))
      3.times do
        GC.start
        GC.compact if GC.respond_to?(:compact)
        check("after!after!", parse(source).render!("value" => "after"))
      end
      Liquid::Variable.define_method(:render, original)
      check("restoredrestored", parse(source).render!("value" => "restored"))
    RUBY
  end

  def test_actual_condition_constructor_override_is_observed
    isolated(<<~RUBY)
      original = Liquid::Condition.method(:new)
      calls = 0
      Liquid::Condition.define_singleton_method(:new) do |*args|
        calls += 1
        original.call(*args)
      end
      template = parse("{% if yes %}ok{% endif %}")
      raise "condition constructor override was bypassed" unless calls.positive?
      check("ok", template.render!("yes" => true))
    RUBY
  end

  def test_private_condition_constructor_preserves_parse_error
    isolated(<<~RUBY)
      Liquid::Condition.singleton_class.send(:private, :new)
      begin
        parse("{% if yes %}ok{% endif %}")
        raise "private condition constructor was bypassed"
      rescue NoMethodError => error
        check(:new, error.name)
      end
    RUBY
  end

  def test_builtin_method_entry_refresh_keeps_direct_compilation
    skip("direct compiler is unavailable") unless Liquid::C::NativeParser::NATIVE_GUARDS

    isolated(<<~RUBY)
      GC.start
      GC.disable
      placeholder = Liquid::C.const_get(:VariablePlaceholder)
      parse("{{ item.name }}").render!("item" => { "name" => "first" })
      String.class_eval do
        alias_method :dup, :dup
        remove_method :dup
      end
      before = ObjectSpace.each_object(placeholder).count
      template = parse("{{ item.name }}")
      raise "builtin entry change disabled direct compilation" unless ObjectSpace.each_object(placeholder).count > before
      check("second", template.render!("item" => { "name" => "second" }))
      GC.enable
      GC.start
      GC.compact if GC.respond_to?(:compact)
      check("third", parse("{{ item.name }}").render!("item" => { "name" => "third" }))
    RUBY
  end

  def test_actual_dup_override_disables_direct_compilation
    skip("direct compiler is unavailable") unless Liquid::C::NativeParser::NATIVE_GUARDS

    isolated(<<~RUBY)
      original = String.instance_method(:dup)
      String.define_method(:dup) { original.bind_call(self) }
      GC.start
      GC.disable
      placeholder = Liquid::C.const_get(:VariablePlaceholder)
      before = ObjectSpace.each_object(placeholder).count
      template = parse("{{ item.name | append: '!' }}")
      check(before, ObjectSpace.each_object(placeholder).count)
      check("ok!", template.render!("item" => { "name" => "ok" }))
    RUBY
  end

  def test_private_builtin_disables_direct_compilation
    skip("direct compiler is unavailable") unless Liquid::C::NativeParser::NATIVE_GUARDS

    isolated(<<~RUBY)
      String.class_eval { private :dup }
      GC.start
      GC.disable
      placeholder = Liquid::C.const_get(:VariablePlaceholder)
      before = ObjectSpace.each_object(placeholder).count
      parse("{{ item.name }}")
      check(before, ObjectSpace.each_object(placeholder).count)
    RUBY
  end

  def isolated(source, before: "")
    extension = $LOADED_FEATURES.find { |path| path.end_with?("/liquid_c.so", "/liquid_c.bundle") }
    prelude = <<~RUBY
      require "liquid/c"
      def check(expected, actual)
        raise "Expected \#{expected.inspect}, got \#{actual.inspect}" unless expected == actual
      end
      def parse(source, **options)
        Liquid::Template.parse(source, error_mode: :warn, line_numbers: true, **options)
      end
    RUBY
    output, status = Open3.capture2e(
      RbConfig.ruby,
      "-I#{File.dirname(extension)}",
      "-I#{File.expand_path("../../lib", __dir__)}",
      "-e",
      before + prelude + source,
    )
    assert(status.success?, output)
  end

  def test_materialization_preserves_state_and_mutable_filters
    isolated(<<~'RUBY')
      template = parse("first\n{{ item.name | append: suffix }}{{ item.name }}")
      check("first\nabaa", template.render!("item" => { "name" => "a" }, "suffix" => "ba"))
      nodes = template.root.nodelist.grep(Liquid::Variable)
      check(2, nodes.size)
      check(2, nodes.first.line_number)
      check(" item.name | append: suffix ", nodes.first.raw)
      raise "different expression identities" unless nodes[0].name.equal?(nodes[1].name)
      raise "shared filter containers" if nodes[0].filters.equal?(nodes[1].filters)
      raise "different node identity" unless nodes.first.equal?(template.root.nodelist.grep(Liquid::Variable).first)
      nodes.first.filters << ["upcase", []]
      check("first\nABAAa", template.render!("item" => { "name" => "a" }, "suffix" => "baa"))
    RUBY
  end

  def test_native_path_and_late_parser_changes_do_not_reparse_ast
    isolated(<<~RUBY)
      GC.start
      GC.disable
      placeholder = Liquid::C.const_get(:VariablePlaceholder)
      before = ObjectSpace.each_object(placeholder).count
      template = parse("{{ item.name | append: '!' }}")
      if Liquid::C::NativeParser::NATIVE_GUARDS
        raise "native compiler was bypassed" unless ObjectSpace.each_object(placeholder).count > before
      end
      Liquid::Variable.define_method(:initialize) { |*| raise "unexpected reparse" }
      Liquid::Parser.define_method(:expression) { raise "unexpected expression parse" }
      check("ok!", template.render!("item" => { "name" => "ok" }))
      node = template.root.nodelist.first
      check("item", node.name.name)
      check(["name"], node.name.lookups)
    RUBY
  end

  def test_render_hooks_installed_after_parse_observe_mutations
    isolated(<<~RUBY)
      template = parse("{{ value }}{{ value }}")
      hook = Module.new do
        def render(context)
          @filters << ["append", ["!"]]
          super
        end
      end
      Liquid::Variable.prepend(hook)
      check("a!a!", template.render!("value" => "a"))
      check("b!!b!!", template.render!("value" => "b"))
    RUBY
  end

  def test_restoring_render_hook_preserves_materialized_mutations
    skip("direct compiler is unavailable") unless Liquid::C::NativeParser::NATIVE_GUARDS

    isolated(<<~RUBY)
      template = parse("{{ value }}")
      original = Liquid::Variable.instance_method(:render)
      Liquid::Variable.define_method(:render) do |context|
        @filters << ["append", ["!"]]
        self.class.define_method(:render, original)
        original.bind_call(self, context)
      end
      check("a!", template.render!("value" => "a"))
      check("b!", template.render!("value" => "b"))
      check("c!", template.render!("value" => "c"))
    RUBY
  end

  def test_tag_can_patch_parser_between_variables
    isolated(<<~RUBY)
      original = Liquid::Variable.instance_method(:initialize)
      tag = Class.new(Liquid::Tag) do
        define_method(:initialize) do |*args|
          super(*args)
          Liquid::Variable.define_method(:initialize) do |markup, context|
            original.bind_call(self, markup, context)
            @filters << ["append", ["!"]]
          end
        end
      end
      env = Liquid::Environment.build { |e| e.register_tag("change", tag) }
      template = parse("{{ value }}{% change %}{{ value }}", environment: env)
      check("aa!", template.render!("value" => "a"))
    RUBY
  end

  def test_cache_is_observable_to_tags_and_retains_identity
    isolated(<<~RUBY)
      tag = Class.new(Liquid::Tag) do
        def initialize(*args)
          super
          cache = parse_context.instance_variable_get(:@expression_cache)
          value = cache.fetch("item.name")
          raise "opaque cache entry" unless value.instance_of?(Liquid::VariableLookup)
          value.lookups.replace(["other"])
        end
      end
      env = Liquid::Environment.build { |e| e.register_tag("edit", tag) }
      template = parse("{{ item.name }}{% edit %}{{ item.name }}", environment: env)
      check("ab", template.render!("item" => { "name" => "a", "other" => "b" }))
      first, last = template.root.nodelist.grep(Liquid::Variable)
      raise "cache identity lost" unless first.name.equal?(last.name)
      check("bb", template.render!("item" => { "name" => "a", "other" => "b" }))
    RUBY
  end

  def test_control_hooks_are_rechecked_after_variable_only_interval
    isolated(<<~RUBY)
      $attachments = []
      original = Liquid::Condition.instance_method(:attach)
      tag = Class.new(Liquid::Tag) do
        define_method(:initialize) do |*args|
          super(*args)
          Liquid::Condition.define_method(:attach) do |body|
            $attachments << body
            original.bind_call(self, body)
          end
        end
      end
      env = Liquid::Environment.build { |e| e.register_tag("change", tag) }
      template = parse(
        "{% if yes %}{{ value }}{% change %}{{ value }}{% else %}{{ other }}{% endif %}" \
          "{% for item in items %}{% if item %}{{ item }}{% endif %}{% endfor %}",
        environment: env,
      )
      check(2, $attachments.size)
      check("aab", template.render!("yes" => true, "value" => "a", "items" => ["b"]))
      check("cb", template.render!("yes" => false, "other" => "c", "items" => ["b"]))
    RUBY
  end

  def test_single_and_multiple_pending_entries_preserve_cache_order_and_identity
    isolated(<<~RUBY)
      caches = []
      tag = Class.new(Liquid::Tag) do
        define_method(:initialize) do |*args|
          super(*args)
          caches << parse_context.instance_variable_get(:@expression_cache).dup
        end
      end
      env = Liquid::Environment.build { |e| e.register_tag("inspect_cache", tag) }
      source = "{{ one }}{{ two | default: one, option: three }}{{ map[key] }}{{ map[key] }}{% inspect_cache %}"
      native = parse(source, environment: env)
      parse(source, environment: env, disable_liquid_c_nodes: true)
      check(caches.last.keys, caches.first.keys)
      caches.first.each do |key, value|
        check(caches.last.fetch(key).class, value.class)
        raise "mutable cache key" unless key.frozen?
      end
      nodes = native.root.nodelist.grep(Liquid::Variable)
      raise "filter cache identity changed" unless nodes[0].name.equal?(nodes[1].filters[0][1][0])
      raise "nested cache identity changed" unless nodes[2].name.equal?(nodes[3].name)
      raise "nested argument identity changed" unless nodes[2].name.lookups.first.equal?(caches.first.fetch("key"))
    RUBY
  end

  def test_repeated_expressions_observe_cache_replacement_after_a_tag
    isolated(<<~RUBY)
      calls = []
      changer = Class.new(Liquid::Tag) do
        define_method(:initialize) do |*args|
          super(*args)
          nested = Liquid::Template.parse("{{ value }}" * 8, error_mode: :warn)
          calls << nested.render!("value" => "i")
          cache = parse_context.instance_variable_get(:@expression_cache)
          cache["value"] = parse_context.parse_expression("other")
          GC.start
          GC.compact if GC.respond_to?(:compact)
        end
      end
      env = Liquid::Environment.build { |e| e.register_tag("change", changer) }
      source = "{{ value }}" * 8 + "{% change %}" + "{{ value }}" * 8
      native = parse(source, environment: env)
      ruby = parse(source, environment: env, disable_liquid_c_nodes: true)
      check("iiiiiiii", calls.first)
      check(2, calls.size)
      check("aaaaaaaa" + "bbbbbbbb", native.render!("value" => "a", "other" => "b"))
      check(ruby.render!("value" => "a", "other" => "b"), native.render!("value" => "a", "other" => "b"))
      nodes = native.root.nodelist.grep(Liquid::Variable)
      raise "earlier identity changed" unless nodes.first.name.equal?(nodes[7].name)
      raise "replacement identity changed" unless nodes[8].name.equal?(nodes.last.name)
      raise "replacement was ignored" if nodes.first.name.equal?(nodes.last.name)
    RUBY
  end

  def test_assignments_preserve_eager_ast_and_filter_mutations
    isolated(<<~RUBY)
      source = "first\n{% assign result = item.name | append: suffix %}{{ result }}"
      native = parse(source)
      ruby = parse(source, disable_liquid_c_nodes: true)
      left = native.root.nodelist.grep(Liquid::Assign).first
      right = ruby.root.nodelist.grep(Liquid::Assign).first
      check(right.to, left.to)
      check(right.from.raw, left.from.raw)
      check(right.from.line_number, left.from.line_number)
      check(Liquid::Variable, left.from.class)
      check("item", left.from.name.name)
      check(["name"], left.from.name.lookups)
      check("first\na!", native.render!("item" => { "name" => "a" }, "suffix" => "!"))
      left.from.filters << ["upcase", []]
      check("first\nB?", native.render!("item" => { "name" => "b" }, "suffix" => "?"))
    RUBY
  end

  def test_assignment_target_syntax_matches_the_ruby_parser
    isolated(<<~'RUBY')
      targets = ["result", "result-name", "result?", "result.name", "result[0]", "result[0]?", "contains", "123"]
      [:lax, :warn, :strict, :strict2].each do |mode|
        targets.each do |target|
          source = "{% assign #{target} = 'value' %}ok"
          observe = lambda do |disabled|
            begin
              template = Liquid::Template.parse(source, error_mode: mode, line_numbers: true,
                disable_liquid_c_nodes: disabled)
              node = template.root.nodelist.first
              [node.to, node.from.raw, template.warnings.map(&:message), template.render!]
            rescue Liquid::SyntaxError => error
              [error.class, error.message]
            end
          end
          check(observe.call(true), observe.call(false))
        end
      end
    RUBY
  end

  def test_assignment_respects_private_variable_constructor
    isolated(<<~RUBY)
      hide = Class.new(Liquid::Tag) do
        def initialize(*args)
          super
          Liquid::Variable.singleton_class.send(:private, :new)
        end
      end
      env = Liquid::Environment.build { |e| e.register_tag("hide", hide) }
      ["{% assign result = 'value' %}", "{% hide %}{% assign result = 'value' %}"].each do |source|
        [:lax, :warn, :strict, :strict2].each do |mode|
          [true, false].each do |disabled|
            visibility = source.include?("{% hide %}") ? :public : :private
            Liquid::Variable.singleton_class.send(visibility, :new)
            begin
              Liquid::Template.parse(source, error_mode: mode, environment: env, disable_liquid_c_nodes: disabled)
              raise "private Variable.new was bypassed"
            rescue NoMethodError => error
              check(:new, error.name)
            ensure
              Liquid::Variable.singleton_class.send(:public, :new)
            end
          end
        end
      end
    RUBY
  end

  def test_assignment_hooks_changed_inside_a_tag_are_observed_once
    isolated(<<~RUBY)
      $calls = []
      original = Liquid::Assign.instance_method(:strict2_parse)
      changer = Class.new(Liquid::Tag) do
        define_method(:initialize) do |*args|
          super(*args)
          Liquid::Assign.define_method(:strict2_parse) do |markup|
            $calls << markup
            original.bind_call(self, markup)
            @from.filters << ["append", ["!"]]
          end
        end
      end
      env = Liquid::Environment.build { |e| e.register_tag("change", changer) }
      template = parse("{% assign result = value %}{% change %}{{ result }}{% assign result = value %}{{ result }}",
        environment: env)
      check(1, $calls.size)
      check("aa!", template.render!("value" => "a"))
    RUBY
  end

  def test_assignment_lexical_variable_constant_changes_are_observed
    isolated(<<~RUBY)
      replacement = Class.new(Liquid::Variable) do
        def initialize(*args)
          super
          @filters << ["append", ["!"]]
        end
      end
      changer = Class.new(Liquid::Tag) do
        define_method(:initialize) do |*args|
          super(*args)
          Liquid::Assign.const_set(:Variable, replacement)
        end
      end
      env = Liquid::Environment.build { |e| e.register_tag("change", changer) }
      template = parse("{% assign result = value %}{% change %}{{ result }}{% assign result = value %}{{ result }}",
        environment: env)
      check("aa!", template.render!("value" => "a"))
      check(replacement, template.root.nodelist.grep(Liquid::Assign).last.from.class)
    RUBY
  end

  def test_assignment_regexp_constant_and_last_match_hooks_are_observed
    [
      "Liquid::Assign.const_set(:Regexp, replacement)",
      "Regexp.define_singleton_method(:last_match) { |index| replacement.last_match(index) }",
    ].each do |change|
      isolated(<<~RUBY)
        replacement = Module.new do
          def self.last_match(index)
            index == 1 ? "other" : "'changed'"
          end
        end
        #{change}
        source = "{% assign result = 'original' %}{{ other }}"
        native = parse(source)
        if #{change.start_with?("Liquid")}
          ruby = parse(source, disable_liquid_c_nodes: true)
          check("changed", ruby.render!)
          check(ruby.render!, native.render!)
        else
          context = Liquid::ParseContext.new(error_mode: :warn)
          expected = Liquid::Assign.send(:new, "assign", "result = 'original'", context)
          actual = native.root.nodelist.grep(Liquid::Assign).first
          check(expected.to, actual.to)
          check(expected.from.name, actual.from.name)
          check("changed", native.render!)
        end
      RUBY
    end
  end

  def test_conditional_lexical_constructor_constants_are_observed
    [false, true].each do |otherwise|
      isolated(<<~RUBY)
        if #{otherwise}
          replacement = Class.new(Liquid::ElseCondition) do
            def evaluate(_context)
              false
            end
          end
          Liquid::If.const_set(:ElseCondition, replacement)
        else
          replacement = Class.new(Liquid::Condition) do
            def initialize(*)
              super(false)
            end
          end
          Liquid::If.const_set(:Condition, replacement)
        end
        source = "{% if flag %}yes{% else %}no{% endif %}"
        native = parse(source)
        ruby = parse(source, disable_liquid_c_nodes: true)
        check(ruby.render!("flag" => #{!otherwise}), native.render!("flag" => #{!otherwise}))
        conditional = native.root.nodelist.first
        node = #{otherwise} ? conditional.blocks.last : conditional.blocks.first
        check(replacement, node.class)
      RUBY
    end
  end

  def test_assignment_autoload_runs_once_on_the_ruby_path
    isolated(<<~RUBY)
      require "tempfile"
      $loads = 0
      Tempfile.create(["variable_hook", ".rb"]) do |file|
        file.write(<<~'HOOK')
          $loads += 1
          replacement = Class.new(Liquid::Variable) do
            def initialize(*args)
              super
              @filters << ["append", ["!"]]
            end
          end
          Liquid::Assign.const_set(:Variable, replacement)
        HOOK
        file.flush
        Liquid::Assign.autoload(:Variable, file.path)
        source = "{% assign result = value %}{{ result }}"
        native = parse(source)
        ruby = parse(source, disable_liquid_c_nodes: true)
        check(1, $loads)
        check("v!", native.render!("value" => "v"))
        check(ruby.render!("value" => "v"), native.render!("value" => "v"))
      end
    RUBY
  end

  def test_keyword_arguments_and_unsupported_syntax_rollback
    isolated(<<~RUBY)
      filter = Module.new do
        def combine(input, *args)
          [input, *args].inspect
        end
      end
      source = "{{ x | combine: a: one, two, a: three, b: four }}|{{ }}|{{ x | append: }}|{{ x }}"
      assigns = { "x" => "v", "one" => 1, "two" => 2, "three" => 3, "four" => 4 }
      native = parse(source)
      ruby = parse(source, disable_liquid_c_nodes: true)
      check(ruby.render(assigns, filters: [filter]), native.render(assigns, filters: [filter]))
      check(ruby.warnings.map(&:message), native.warnings.map(&:message))
    RUBY
  end

  def test_interrupts_from_direct_variable_evaluation
    isolated(<<~RUBY)
      filter = Module.new do
        def stop(value)
          @context.push_interrupt(Liquid::BreakInterrupt.new)
          value
        end
      end
      template = parse("{% for i in (1..2) %}a{{ 'X' | stop }}tail{% endfor %}end")
      check("aXend", template.render!({}, filters: [filter]))
    RUBY
  end

  def test_tracing_runs_the_original_parser
    isolated(<<~RUBY)
      calls = 0
      trace = TracePoint.new(:call) { |event| calls += 1 if event.defined_class == Liquid::Variable && event.method_id == :initialize }
      template = trace.enable { parse("{{ value }}{{ value }}") }
      check(2, calls)
      check("xx", template.render!("value" => "x"))
    RUBY
  end

  def test_standard_headers_preserve_ast_and_warnings
    isolated(<<~RUBY)
      sources = [
        "{% if x contains 'a' and y != empty or z %}{{ x }}{% endif %}",
        "{% for item in values reversed limit: 2 offset: 1 %}{{ item }}{% else %}empty{% endfor %}",
        "{% if x == %}yes{% endif %}",
        "{% for item in values limit: %}{{ item }}{% endfor %}",
      ]
      sources.each do |source|
        [:warn, :strict, :strict2].each do |mode|
          outcomes = [false, true].map do |disabled|
            begin
              t = Liquid::Template.parse(source, error_mode: mode, line_numbers: true, disable_liquid_c_nodes: disabled)
              [t.render!("x" => "a", "y" => [1], "values" => [1, 2, 3]), t.warnings.map(&:message)]
            rescue Liquid::SyntaxError => e
              [e.class.name, e.message, e.line_number]
            end
          end
          check(outcomes[1], outcomes[0])
        end
      end
    RUBY
  end

  def test_included_constructor_hooks_before_and_after_extension_loading
    [false, true].each do |before_load|
      setup = <<~RUBY
        require "liquid"
        $constructor_calls = []
        Liquid::If.include(Module.new do
          def initialize(*args)
            $constructor_calls << args.first
            super
          end
        end)
      RUBY
      body = <<~RUBY
        template = parse("{% if x %}{{ x }}{% endif %}")
        check(["if"], $constructor_calls)
        check("yes", template.render!("x" => "yes"))
      RUBY
      before_load ? isolated(body, before: setup) : isolated(setup + body)
    end
  end

  def test_existing_module_can_gain_a_super_hook_between_parses
    isolated(<<~RUBY)
      hook = Module.new
      Liquid::If.include(hook)
      check("yes", parse("{% if x %}yes{% endif %}").render!("x" => true))
      $calls = 0
      hook.module_eval do
        def initialize(*args)
          $calls += 1
          super
        end
      end
      check("yes", parse("{% if x %}yes{% endif %}").render!("x" => true))
      check(1, $calls)
    RUBY
  end

  def test_tag_can_reenter_parser_without_sharing_guard_state
    isolated(<<~RUBY)
      tag = Class.new(Liquid::Tag) do
        def initialize(*args)
          super
          nested = Liquid::Template.parse("{% if inner %}{{ inner }}{% endif %}", error_mode: :warn)
          raise "reentry failed" unless nested.render!("inner" => "nested") == "nested"
        end
      end
      env = Liquid::Environment.build { |e| e.register_tag("nested", tag) }
      template = parse("{{ value }}{% nested %}{% if value %}{{ value }}{% endif %}", environment: env)
      check("xx", template.render!("value" => "x"))
    RUBY
  end

  def test_gc_finalizer_method_changes_are_visible_after_a_tag
    isolated(<<~RUBY)
      original = Liquid::Variable.instance_method(:initialize)
      callback = proc do
        Liquid::Variable.define_method(:initialize) do |markup, context|
          original.bind_call(self, markup, context)
          @filters << ["append", ["!"]]
        end
      end
      tag = Class.new(Liquid::Tag) do
        define_method(:initialize) do |*args|
          super(*args)
          Thread.new { ObjectSpace.define_finalizer(Object.new, callback); nil }.join
          GC.start
        end
      end
      env = Liquid::Environment.build { |e| e.register_tag("collect", tag) }
      template = parse("{{ value }}{% collect %}{{ value }}", environment: env)
      check("aa!", template.render!("value" => "a"))
    RUBY
  end

  def test_compaction_and_collection_preserve_lazy_ast
    isolated(<<~RUBY)
      source = "{% for item in values %}{% if item.name %}{{ item.name | append: suffix }}{% else %}none{% endif %}{% endfor %}"
      template = parse(source)
      3.times do
        GC.start
        GC.verify_compaction_references(double_heap: true, toward: :empty) if GC.respond_to?(:verify_compaction_references)
        check("a!b!", template.render!("values" => [{ "name" => "a" }, { "name" => "b" }], "suffix" => "!"))
      end
      loop_tag = template.root.nodelist.first
      nodes = loop_tag.nodelist.first.nodelist.first.blocks.first.attachment.nodelist
      nodes.first.filters << ["upcase", []]
      check("A!B!", template.render!("values" => [{ "name" => "a" }, { "name" => "b" }], "suffix" => "!"))
    RUBY
  end

  def test_control_parser_wrapper_overrides_are_observed
    isolated(<<~RUBY)
      original = Liquid::If.instance_method(:parse_with_selected_parser)
      $calls = 0
      Liquid::If.define_method(:parse_with_selected_parser) do |markup|
        $calls += 1
        original.bind_call(self, markup)
      end
      template = parse("{% if value %}{{ value }}{% elsif other %}other{% endif %}")
      check(2, $calls)
      check("yes", template.render!("value" => "yes"))
    RUBY
  end

  def test_private_condition_attachment_preserves_parse_error
    isolated(<<~RUBY)
      Liquid::Condition.send(:private, :attach)
      begin
        parse("{% if value %}yes{% endif %}")
        raise "private attachment hook was bypassed"
      rescue NoMethodError => error
        check(:attach, error.name)
      end
    RUBY
  end

  def test_mutable_filter_names_are_distinct_and_keep_encoding
    isolated(<<~RUBY)
      template = parse("{{ value | append: suffix }}{{ value | append: suffix }}")
      first, second = template.root.nodelist
      check(Encoding::UTF_8, first.filters.first.first.encoding)
      raise "shared filter names" if first.filters.first.first.equal?(second.filters.first.first)
      first.filters.first.first.replace("prepend")
      check("!aa!", template.render!("value" => "a", "suffix" => "!"))
    RUBY
  end

  def test_array_render_materialization_survives_minor_collection
    isolated(<<~RUBY)
      template = parse("{{ values }}")
      2.times { GC.start }
      check("ab", template.render!("values" => ["a", "b"]))
      5.times { GC.start(full_mark: false, immediate_sweep: true) }
      check("cd", template.render!("values" => ["c", "d"]))
      node = template.root.nodelist.first
      check([], node.filters)
      node.filters << ["join", ["-"]]
      check("c-d", template.render!("values" => ["c", "d"]))
    RUBY
  end

  def test_long_lookup_chains_preserve_cache_identity_and_nil_exit
    isolated(<<~'RUBY')
      [60, 61, 62, 256].each do |depth|
        value = "ok"
        depth.times { value = { "child" => value } }
        markup = "item" + ".child" * depth
        template = parse("{{ #{markup} }}{{ #{markup} }}")
        check("okok", template.render!("item" => value))
        nodes = template.root.nodelist
        check(depth, nodes.first.name.lookups.size)
        raise "cache identity lost" unless nodes.first.name.equal?(nodes.last.name)
        check("", template.render!("item" => { "child" => nil }))
      end
      value = ["a", "b"]
      61.times { value = { "child" => value } }
      source = "{{ item" + ".child" * 61 + ".first }}{{ item" + ".child" * 61 + ".size }}"
      check("a2", parse(source).render!("item" => value))
    RUBY
  end

  def test_lookup_accessors_used_by_custom_compilation_are_observed
    isolated(<<~RUBY)
      calls = []
      [:name, :lookups].each do |name|
        original = Liquid::VariableLookup.instance_method(name)
        Liquid::VariableLookup.define_method(name) do
          calls << name
          original.bind_call(self)
        end
      end
      template = parse("{{ item.name }}")
      raise "name accessor was bypassed" unless calls.include?(:name)
      raise "lookup accessor was bypassed" unless calls.include?(:lookups)
      check("ok", template.render!("item" => { "name" => "ok" }))
    RUBY
  end

  def test_variable_parser_regexp_hook_is_observed
    isolated(<<~'RUBY')
      calls = 0
      original = Regexp.instance_method(:match?)
      Regexp.define_method(:match?) do |value, *args|
        calls += 1 if source == '\A\s*-\.\d'
        original.bind_call(self, value, *args)
      end
      template = parse("{{ value }}")
      check(1, calls)
      check("ok", template.render!("value" => "ok"))
    RUBY
  end

  def test_replacing_variable_constant_affects_new_parses_only
    isolated(<<~RUBY)
      previous = parse("{{ value }}")
      original_class = Liquid::Variable
      replacement = Class.new(original_class) do
        def initialize(*args)
          super
          @filters << ["append", ["!"]]
        end
      end
      Liquid.send(:remove_const, :Variable)
      Liquid.const_set(:Variable, replacement)
      current = parse("{{ value }}")
      check("a!", current.render!("value" => "a"))
      check(replacement, current.root.nodelist.first.class)
      check(original_class, previous.root.nodelist.first.class)
      check("a", previous.render!("value" => "a"))
    RUBY
  end

  def test_unknown_filter_names_do_not_become_permanent_symbols
    isolated(<<~'RUBY')
      names = 32.times.map { |i| "temporary_filter_#{Process.pid}_#{i}" }
      source = names.map { |name| "{{ value | #{name} }}" }.join
      Thread.new do
        template = parse(source)
        check("x" * 32, template.render!("value" => "x"))
        nil
      end.join
      5.times { GC.start }
      remaining = Symbol.all_symbols.map(&:to_s) & names
      check([], remaining)
    RUBY
  end
end
