# frozen_string_literal: true

require_relative "boot"
require "minitest/autorun"
require_relative "fixtures"

class Liquid514SafetyTest < Minitest::Test
  def test_gc_compaction_keeps_compiled_values_alive
    source = 'é{{ values[0] | append: "!" }}{% capture x %}{{ values[1] }}{% endcapture %}{{ x }}'
    template = Liquid::Template.parse(source, error_mode: :strict)
    5.times do
      GC.start
      if GC.respond_to?(:verify_compaction_references)
        options = RUBY_VERSION >= "3.3" ? { expand_heap: true } : { double_heap: true }
        GC.verify_compaction_references(**options, toward: :empty)
      end
      assert_equal("éA!B", template.render!("values" => ["A", "B"]))
    end
  end

  def test_gc_stress_parse_render
    old_stress = GC.stress
    begin
      GC.stress = true
      template = Liquid::Template.parse('{{ value | append: "!" }}', error_mode: :strict)
      assert_equal("é!", template.render!("value" => "é"))
    ensure
      GC.stress = old_stress
    end
  end

  def test_exception_renderer_raises_without_corrupting_vm
    environment = Liquid::Environment.build { |env| env.register_filter(Compatibility::Filters) }
    context = Liquid::Context.build(environment: environment)
    context.exception_renderer = ->(_error) { raise "renderer failure" }
    template = Liquid::Template.parse("A{{ 1 | explode }}Z", environment: environment, error_mode: :strict)
    3.times do
      error = assert_raises(RuntimeError) { template.render(context) }
      assert_equal("renderer failure", error.message)
    end
    assert_equal("ok", Liquid::Template.parse("{{ value }}").render!("value" => "ok"))
  end

  def test_syntax_error_does_not_poison_next_parse
    5.times do
      assert_raises(Liquid::SyntaxError) { Liquid::Template.parse("{{ x[ }}", error_mode: :strict) }
      assert_equal("ok", Liquid::Template.parse("{{ x }}", error_mode: :strict).render!("x" => "ok"))
    end
  end

  def test_whitespace_only_expression_does_not_overread
    ["", " ", "\t", "\r\n", " " * 4096].each do |expression|
      assert_equal("AZ", Liquid::Template.parse("A{{#{expression}}}Z", error_mode: :strict).render!)
    end
  end

  def test_large_integer_does_not_overflow_native_conversion
    value = 2**100
    assert_equal(value.to_s, Liquid::Template.parse("{{ #{value} }}").render!)
    assert_raises(RangeError) do
      Liquid::Template.parse("{{ x[index] }}").render!("x" => [1], "index" => value)
    end
  end

  def test_inline_comment_inside_liquid_tag_terminates
    template = Liquid::Template.parse("{% liquid\n# ignore this\necho 'ok'\n%}", error_mode: :strict)
    assert_equal("ok", template.render!)
  end

  def test_native_source_size_boundary_and_fallback
    maximum = (1 << 24) - 1
    [maximum - 1, maximum, maximum + 1].each do |size|
      source = "x" * size
      template = Liquid::Template.parse(source, error_mode: :strict)
      assert_equal(size, template.render!.bytesize)
      next unless Compatibility::ENGINE == "c"

      expected = size <= maximum ? "Liquid::C::BlockBody" : "Liquid::BlockBody"
      assert_equal(expected, template.root.body.class.name)
    end
  end

  def test_constant_table_does_not_wrap_at_65536
    require "digest"
    [65_535, 65_536, 65_537].each do |count|
      values = Array.new(count) { |index| (65_536 + index).to_s }
      source = values.map { |value| "{{ #{value} }}|" }.join
      expected = values.join("|") + "|"
      actual = Liquid::Template.parse(source, error_mode: :strict).render!
      assert_equal(Digest::SHA256.hexdigest(expected), Digest::SHA256.hexdigest(actual), "constants=#{count}")
    end
  end

  def test_positional_filter_argument_boundary
    filter = Module.new do
      def argument_count(_input, *arguments)
        arguments.size.to_s
      end
    end
    environment = Liquid::Environment.build { |env| env.register_filter(filter) }
    [254, 255, 256].each do |count|
      source = "{{ 0 | argument_count: #{Array.new(count, "1").join(",")} }}"
      template = Liquid::Template.parse(source, environment: environment, error_mode: :strict)
      assert_equal(count.to_s, template.render!, "arguments=#{count}")
    end
  end

  def test_keyword_filter_argument_boundary
    filter = Module.new do
      def option_count(_input, options = {})
        options.size.to_s
      end
    end
    environment = Liquid::Environment.build { |env| env.register_filter(filter) }
    [255, 256].each do |count|
      options = Array.new(count) { |index| "key#{index}: 1" }.join(",")
      template = Liquid::Template.parse(
        "{{ 0 | option_count: #{options} }}",
        environment: environment,
        error_mode: :strict,
      )
      assert_equal(count.to_s, template.render!, "keywords=#{count}")
    end
  end

  def test_variable_render_hook_is_called
    hook = Module.new do
      def render(context)
        context.registers[:variable_renders] = context.registers.fetch(:variable_renders, 0) + 1
        super
      end
    end
    Liquid::Variable.prepend(hook)
    context = Liquid::Context.build(environments: { "value" => "ok" })
    template = Liquid::Template.parse("{{ value }}", error_mode: :strict)
    assert_equal("ok", template.render!(context))
    assert_equal(1, context.registers[:variable_renders])
  end

  def test_variable_render_hook_added_after_compilation
    template = Liquid::Template.parse("A{{ value }}Z", error_mode: :strict)
    hook = Module.new do
      def render(context)
        context.registers[:late_variable_renders] = context.registers.fetch(:late_variable_renders, 0) + 1
        super
      end
    end
    Liquid::Variable.prepend(hook)
    context = Liquid::Context.build(environments: { "value" => "ok" })
    2.times { assert_equal("AokZ", template.render!(context)) }
    assert_equal(2, context.registers[:late_variable_renders])
  end

  def test_variable_output_hooks_follow_method_changes
    require "open3"
    require "rbconfig"
    [:render_to_output_buffer, :render_obj_to_output].product(
      [:direct, :prepend, :late_method, :preloaded, :nested_prepend, :included_module],
    ).each do |method_name, installation|
      arguments = method_name == :render_to_output_buffer ? "context, output" : "obj, output"
      code = <<~RUBY
        require "bundler/setup"
        require "liquid"
        hook = Module.new
        install = -> do
          hook.module_eval(<<~'HOOK')
            def #{method_name}(#{arguments})
              output << "["
              super
              output << "]"
              output
            end
          HOOK
        end
        install.call if #{installation == :preloaded}
        Liquid::Variable.prepend(hook) if #{installation == :preloaded}
        unless ENV["LIQUID_ENGINE"] == "pure"
          $LOAD_PATH.unshift(ENV["LIQUID_C_EXTENSION_DIR"]) if ENV["LIQUID_C_EXTENSION_DIR"]
          require "liquid/c"
          Liquid::C.enabled = ENV["LIQUID_ENGINE"] != "disabled"
          Liquid::ParseContext.liquid_c_nodes_disabled = ENV["LIQUID_ENGINE"] == "no_vm"
        end
        template = Liquid::Template.parse("A{{ value }}Z", error_mode: :strict)
        case #{installation.inspect}
        when :direct
          original = Liquid::Variable.instance_method(#{method_name.inspect})
          Liquid::Variable.define_method(#{method_name.inspect}) do |value, output|
            output << "["
            original.bind_call(self, value, output)
            output << "]"
            output
          end
        when :prepend
          install.call
          Liquid::Variable.prepend(hook)
        when :late_method
          Liquid::Variable.prepend(hook)
          install.call
        when :nested_prepend
          parent = Module.new
          Liquid::Variable.prepend(parent)
          install.call
          parent.prepend(hook)
        when :included_module
          original = Liquid::Variable.instance_method(#{method_name.inspect})
          original_module = Module.new
          original_module.define_method(#{method_name.inspect}) do |value, output|
            original.bind_call(self, value, output)
          end
          hook.include(original_module)
          Liquid::Variable.send(:remove_method, #{method_name.inspect})
          Liquid::Variable.include(hook)
          install.call
        end
        2.times { print template.render!("value" => "v") }
        if #{installation == :late_method}
          hook.send(:remove_method, #{method_name.inspect})
          print template.render!("value" => "v")
        end
      RUBY
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", code)
      assert_predicate(status, :success?, "#{method_name}/#{installation}: #{stderr}")
      expected = "A[v]ZA[v]Z"
      expected += "AvZ" if installation == :late_method
      assert_equal(expected, stdout, "#{method_name}/#{installation}")
    end
  end

  def test_variable_cache_handles_reentrant_and_raising_callbacks
    require "open3"
    require "rbconfig"
    [:method_added, :raising_method_added, :prepended].each do |callback|
      code = <<~RUBY
        require_relative "test/compatibility/boot"
        template = Liquid::Template.parse("{{ value }}")
        original = Liquid::Variable.instance_method(:render_obj_to_output)
        hook = Module.new do
          define_method(:render_obj_to_output) do |value, output|
            output << "["
            original.bind_call(self, value, output)
            output << "]"
          end
        end
        if #{callback == :prepended}
          hook.define_singleton_method(:prepended) do |_base|
            print template.render!("value" => "v")
          end
          Liquid::Variable.prepend(hook)
        else
          Liquid::Variable.define_singleton_method(:method_added) do |name|
            if name == :render_obj_to_output
              print template.render!("value" => "v")
              raise "callback failure" if #{callback == :raising_method_added}
            end
          end
          begin
            Liquid::Variable.define_method(:render_obj_to_output, hook.instance_method(:render_obj_to_output))
          rescue RuntimeError => error
            raise unless error.message == "callback failure"
          end
        end
        print template.render!("value" => "v")
      RUBY
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", code)
      assert_predicate(status, :success?, "#{callback}: #{stderr}")
      assert_equal("[v][v]", stdout, callback.to_s)
    end
  end

  def test_native_render_avoids_ruby_hook_checks_per_block
    return unless Compatibility::ENGINE == "c"

    template = Liquid::Template.parse("{% for i in (1..1000) %}{% if i %}{{ i }}{% endif %}{% endfor %}")
    assert_instance_of(Liquid::C::BlockBody, template.root.body)
    assert_nil(Liquid::Context.instance_method(:evaluate).source_location)
    calls = []
    trace = TracePoint.new(:call, :c_call) do |event|
      identity_check = [:c_native_render?, :instance_method].include?(event.method_id)
      ruby_variable_render = event.event == :call && event.self.is_a?(Liquid::Variable) &&
        [:render, :render_to_output_buffer, :render_obj_to_output].include?(event.method_id)
      calls << event.method_id if identity_check || ruby_variable_render
    end
    output = trace.enable { template.render! }
    assert_equal((1..1000).to_a.join, output)
    assert_empty(calls)
  end

  def test_switching_engine_with_frozen_variable_class
    code = <<~RUBY
      require_relative "test/compatibility/boot"
      Liquid::Variable.freeze
      if defined?(Liquid::C)
        Liquid::C.enabled = false
        disabled = Liquid::Template.parse("{{ value }}")
        print disabled.render!("value" => "ruby")
        Liquid::C.enabled = true
      end
      print Liquid::Template.parse("{{ value }}").render!("value" => "native")
    RUBY
    expected = Compatibility::ENGINE == "pure" ? "native" : "rubynative"
    assert_variable_dispatch_subprocess(code, expected)
  end

  def test_variable_dispatch_handles_frozen_objects_and_callback_bypasses
    cases = {
      frozen_class: <<~RUBY,
        hook = Module.new
        Liquid::Variable.prepend(hook)
        template = Liquid::Template.parse('{{ value }}')
        Liquid::Variable.freeze
        hook.module_eval do
          def render_obj_to_output(obj, output)
            output << '['
            super
            output << ']'
          end
        end
      RUBY
      frozen_singleton_module: <<~'RUBY',
        hook = Module.new do
          def render(context)
            "[#{super}]"
          end
        end
        hook.singleton_class.freeze
        template = Liquid::Template.parse('{{ value }}')
        Liquid::Variable.prepend(hook)
      RUBY
      direct_prepend_features: <<~'RUBY',
        template = Liquid::Template.parse('{{ value }}')
        hook = Module.new do
          def render(context)
            "[#{super}]"
          end
        end
        hook.send(:prepend_features, Liquid::Variable)
      RUBY
      prepended_method_added: <<~'RUBY',
        template = Liquid::Template.parse('{{ value }}')
        Liquid::Variable.singleton_class.prepend(Module.new do
          def method_added(_name)
          end
        end)
        original = Liquid::Variable.instance_method(:render)
        Liquid::Variable.define_method(:render) do |context|
          "[#{original.bind_call(self, context)}]"
        end
      RUBY
    }
    cases.each do |name, code|
      assert_variable_dispatch_subprocess(code + '2.times { print template.render!("value" => "v") }', "[v][v]", name)
    end
  end

  def test_filter_can_install_output_hook_for_current_variable
    code = <<~RUBY
      filter = Module.new do
        def install_hook(value)
          Liquid::Variable.prepend(Module.new do
            def render_obj_to_output(obj, output)
              output << '['
              super
              output << ']'
            end
          end)
          value
        end
      end
      environment = Liquid::Environment.build { |env| env.register_filter(filter) }
      template = Liquid::Template.parse('{{ value | install_hook }}{{ value }}', environment: environment)
      print template.render!('value' => 'v')
    RUBY
    assert_variable_dispatch_subprocess(code, "[v][v]")
  end

  def test_singleton_variable_render_is_used_after_tree_access
    code = <<~'RUBY'
      template = Liquid::Template.parse('A{{ value }}Z')
      node = template.root.nodelist.grep(Liquid::Variable).first
      def node.render(context)
        "[#{super}]"
      end
      2.times { print template.render!('value' => 'v') }
    RUBY
    assert_variable_dispatch_subprocess(code, "A[v]ZA[v]Z")
  end

  def test_array_output_dispatches_hook_for_every_nested_value
    code = <<~RUBY
      Liquid::Variable.prepend(Module.new do
        def render_obj_to_output(obj, output)
          output << '['
          super
          output << ']'
        end
      end)
      template = Liquid::Template.parse('{{ value }}')
      print template.render!('value' => ['a', ['b', nil]])
    RUBY
    assert_variable_dispatch_subprocess(code, "[[a][[b][]]]")
  end

  def test_reading_tree_inside_filter_does_not_repeat_filter_execution
    code = <<~RUBY
      template = nil
      calls = 0
      filter = Module.new do
        define_method(:read_tree) do |value|
          calls += 1
          template.root.nodelist
          value
        end
      end
      environment = Liquid::Environment.build { |env| env.register_filter(filter) }
      template = Liquid::Template.parse('{{ value | read_tree }}', environment: environment)
      2.times { print template.render!('value' => 'v') }
      print ':', calls
    RUBY
    assert_variable_dispatch_subprocess(code, "vv:2")
  end

  def test_variable_render_can_reenter_with_live_filter_arguments
    code = <<~RUBY
      variable = nil
      Liquid::Variable.prepend(Module.new do
        define_method(:render) do |context|
          variable = self
          super(context)
        end
      end)
      context = Liquid::Context.new('x' => 'x')
      nested = false
      context.environments.first['trigger'] = proc do |ctx|
        if nested
          '!'
        else
          begin
            nested = true
            variable.render(ctx)
          ensure
            nested = false
          end
        end
      end
      print Liquid::Template.parse('{{ x | append: trigger }}').render!(context)
    RUBY
    assert_variable_dispatch_subprocess(code, "xx!")
  end

  def test_recursive_array_output_raises_without_crashing
    value = []
    value << value
    template = Liquid::Template.parse("{{ value }}", error_mode: :strict)
    assert_raises(SystemStackError) { template.render!("value" => value) }
    assert_equal("ok", template.render!("value" => "ok"))
  end

  def test_variable_render_hook_installed_before_extension_load
    require "open3"
    require "rbconfig"
    code = <<~RUBY
      require "bundler/setup"
      require "liquid"
      hook = Module.new do
        def render(context)
          context.registers[:calls] = context.registers.fetch(:calls, 0) + 1
          super
        end
      end
      Liquid::Variable.prepend(hook)
      unless ENV["LIQUID_ENGINE"] == "pure"
        $LOAD_PATH.unshift(ENV["LIQUID_C_EXTENSION_DIR"]) if ENV["LIQUID_C_EXTENSION_DIR"]
        require "liquid/c"
        Liquid::C.enabled = ENV["LIQUID_ENGINE"] != "disabled"
        Liquid::ParseContext.liquid_c_nodes_disabled = ENV["LIQUID_ENGINE"] == "no_vm"
      end
      context = Liquid::Context.build(environments: { "value" => "ok" })
      template = Liquid::Template.parse("A{{ value }}Z", error_mode: :strict)
      print template.render!(context), ":", context.registers[:calls]
    RUBY
    command = [RbConfig.ruby, "-Ilib"]
    stdout, stderr, status = Open3.capture3(*command, "-e", code)
    assert_predicate(status, :success?, stderr)
    assert_equal("AokZ:1", stdout)
  end

  private

  def assert_variable_dispatch_subprocess(code, expected, label = nil)
    require "open3"
    require "rbconfig"
    source = "require_relative \"test/compatibility/boot\"\n" + code
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", source)
    assert_predicate(status, :success?, "#{label}: #{stderr}")
    assert_equal(expected, stdout, label.to_s)
  end
end
