# frozen_string_literal: true

require "test_helper"
require "rbconfig"
require "objspace"
require "weakref"
require_relative "../compatibility/process_runner"

class AuditRegressionTest < Minitest::Test
  def test_discarded_case_prologue_releases_nested_bytecode
    source = "{% case x %}{% if y %}" + ("z" * 1_048_576) + "{% endif %}{% when 1 %}OK{% endcase %}"
    template = Thread.new { Liquid::Template.parse(source, error_mode: :strict) }.value
    GC.start(full_mark: true, immediate_sweep: true)
    sizes = ObjectSpace.each_object(Liquid::C::DocumentBody).map { |body| ObjectSpace.memsize_of(body) }
    assert_operator(sizes.max, :<, 4096)
    assert_equal("OK", template.render!("x" => 1))
    assert_equal(["OK"], template.root.nodelist.first.nodelist.first.nodelist)
  end

  def test_external_reference_to_discarded_nested_body_cannot_read_reused_bytes
    return isolate(__method__) unless ENV["LIQUID_AUDIT_CASE"] == __method__.to_s

    captured = []
    capture = Module.new do
      define_method(:parse) do |tokens|
        result = super(tokens)
        captured << self
        result
      end
    end
    Liquid::If.prepend(capture)
    template = Liquid::Template.parse(
      "{% case x %}{% if a %}LOST{% endif %}{% when 1 %}PRESENT{% endcase %}", error_mode: :strict
    )
    body = captured.last.blocks.first.attachment
    assert_equal("PRESENT", template.render!("x" => 1))
    error = assert_raises(RuntimeError) { body.render_to_output_buffer(Liquid::Context.new("a" => true), +"") }
    assert_match(/discarded/, error.message)
  end

  def test_disabled_context_setters_release_hidden_vm_references
    context = Liquid::Context.build
    template = Liquid::Template.parse("{{ value }}")
    payload_ref = Thread.new do
      payload = "g" * 1_048_576
      context.global_filter = lambda do |value|
        payload.bytesize
        value
      end
      template.render!(context)
      WeakRef.new(payload)
    end.value
    strainer_ref = WeakRef.new(context.strainer)
    Liquid::C.enabled = false
    context.global_filter = nil
    context.add_filters(Module.new)
    GC.start(full_mark: true, immediate_sweep: true)
    refute_predicate(payload_ref, :weakref_alive?)
    refute_predicate(strainer_ref, :weakref_alive?)
  ensure
    Liquid::C.enabled = true
  end

  def test_parsing_cleanup_releases_free_assemblers_with_unfinished_body
    2.times do |order|
      context = Liquid::ParseContext.new
      context.start_liquid_c_parsing
      unfinished = [Liquid::C::BlockBody.new(context), Liquid::C::BlockBody.new(context)]
      body = Liquid::C::BlockBody.new(context)
      body.parse(context.new_tokenizer("x" * 1_048_576), context) { |*| }
      body.freeze
      pool = ObjectSpace.each_object(Liquid::C::VMAssemblerPool).find do |candidate|
        ObjectSpace.memsize_of(candidate) > 1_048_576
      end
      refute_nil(pool)
      context.cleanup_liquid_c_parsing
      unfinished[order] = nil
      GC.start(full_mark: true, immediate_sweep: true)
      assert_operator(ObjectSpace.memsize_of(pool), :<, 4096)
      assert_predicate(unfinished[1 - order], :blank?)
    end
  end

  def test_blank_body_compacts_raw_bytecode_and_preserves_ast
    template = Liquid::Template.parse("{% if x %}" + (" " * 1_048_576) + "{% endif %}", error_mode: :strict)
    GC.start(full_mark: true, immediate_sweep: true)
    sizes = ObjectSpace.each_object(Liquid::C::DocumentBody).map { |body| ObjectSpace.memsize_of(body) }
    assert_operator(sizes.max, :<, 4096)
    assert_equal([], template.root.nodelist.first.blocks.first.attachment.nodelist)
    assert_equal("", template.render!("x" => true))
  end

  def test_nested_blank_conditions_keep_lookup_jumps_valid
    source = "{% if a.b %}" + (" " * 200_000) + "{% if c %}" + (" " * 200_000) + "{% endif %}{% endif %}"
    template = Liquid::Template.parse(source, error_mode: :strict)
    GC.start(full_mark: true, immediate_sweep: true)
    sizes = ObjectSpace.each_object(Liquid::C::DocumentBody).map { |body| ObjectSpace.memsize_of(body) }
    assert_operator(sizes.max, :<, 4096)
    assert_equal("", template.render!("a" => { "b" => true }, "c" => true))
    assert_equal("", template.render!("a" => {}, "c" => true))
    nested = template.root.nodelist.first.blocks.first.attachment.nodelist
    assert_equal(1, nested.size)
    assert_equal([], nested.first.blocks.first.attachment.nodelist)
  end

  def test_variable_materialization_exposes_original_parse_context
    [true, false].each do |enabled|
      Liquid::C.enabled = enabled
      variable = Liquid::Template.parse("{{ value }}", error_mode: :warn).root.nodelist.first
      context = variable.parse_context
      warnings = context.warnings
      cache = context.instance_variable_get(:@expression_cache)
      GC.start(full_mark: true, immediate_sweep: true)
      assert_same(context, variable.parse_context)
      assert_same(warnings, variable.parse_context.warnings)
      assert_same(cache, variable.parse_context.instance_variable_get(:@expression_cache))
    end
  ensure
    Liquid::C.enabled = true
  end

  def test_finished_document_reports_and_releases_spare_capacity
    template = Liquid::Template.parse("x" * 600_000)
    sizes = ObjectSpace.each_object(Liquid::C::DocumentBody).map { |body| ObjectSpace.memsize_of(body) }
    assert(sizes.any? { |size| size >= 600_000 && size < 700_000 }, sizes.inspect)
    assert_equal("x" * 600_000, template.render!)
  end

  def test_compiled_body_copies_keep_document_alive
    return isolate(__method__) unless ENV["LIQUID_AUDIT_CASE"] == __method__.to_s

    original = Liquid::Template.parse("before {{ value }} after").root.body
    copies = [original.dup, original.clone]
    refute_predicate(copies.first, :frozen?)
    assert_predicate(copies.last, :frozen?)
    # Drop the original body's Ruby reference before testing the native owner.
    original = nil # rubocop:disable Lint/UselessAssignment
    GC.start
    GC.verify_compaction_references(expand_heap: true, toward: :empty) if GC.respond_to?(:verify_compaction_references)
    copies.each do |body|
      assert_equal("before ok after", body.render_to_output_buffer(Liquid::Context.new("value" => "ok"), +""))
    end
    assert_same(copies.first, copies.first.freeze)
    assert_predicate(copies.first, :frozen?)
  end

  def test_intermediate_body_copies_own_their_assemblers
    context = Liquid::ParseContext.new
    context.start_liquid_c_parsing
    original = Liquid::C::BlockBody.new(context)
    copy = original.dup
    tokenizer = context.new_tokenizer("original {{ value }}")
    original.parse(tokenizer, context) { |*| }
    copy.parse(context.new_tokenizer("copy {{ value }}"), context) { |*| }
    original.freeze
    copy.freeze
    context.cleanup_liquid_c_parsing
    assert_equal("original ok", original.render_to_output_buffer(Liquid::Context.new("value" => "ok"), +""))
    assert_equal("copy ok", copy.render_to_output_buffer(Liquid::Context.new("value" => "ok"), +""))
  end

  def test_uninitialized_body_raises_instead_of_dereferencing_null
    body = Liquid::C::BlockBody.allocate
    assert_raises(RuntimeError) { body.add_lookup_command("foo") }
    assert_raises(RuntimeError) { body.freeze }
    assert_raises(RuntimeError) { body.remove_blank_strings }
  end

  def test_frozen_intermediate_copy_rejects_mutation
    context = Liquid::ParseContext.new
    context.start_liquid_c_parsing
    body = Liquid::C::BlockBody.new(context).clone(freeze: true)
    assert_predicate(body, :frozen?)
    assert_raises(FrozenError) { body.parse(context.new_tokenizer("text"), context) { |*| } }
    assert_raises(FrozenError) { body.add_lookup_command("size") }
  ensure
    context&.cleanup_liquid_c_parsing
  end

  def test_body_cannot_compile_after_parse_context_cleanup
    context = Liquid::ParseContext.new
    context.start_liquid_c_parsing
    body = Liquid::C::BlockBody.new(context)
    context.cleanup_liquid_c_parsing
    assert_raises(RuntimeError) { body.freeze }
  end

  def test_copy_of_incomplete_bytecode_cannot_be_frozen
    original = Liquid::Variable.instance_method(:compile_evaluate)
    Liquid::Variable.define_method(:compile_evaluate) do |code|
      assert_error = false
      begin
        code.dup.freeze
      rescue RuntimeError
        assert_error = true
      end
      raise "incomplete bytecode was frozen" unless assert_error

      original.bind_call(self, code)
    end
    assert_equal("ok", Liquid::Template.parse("{{ value }}").render!("value" => "ok"))
  ensure
    Liquid::Variable.define_method(:compile_evaluate, original) if original
  end

  def test_liquid_tokenizer_is_restored_after_a_tag_exception
    tag = Class.new(Liquid::Tag) do
      def initialize(*) # rubocop:disable Lint/MissingSuper -- exercise failure before tag initialization
        raise "expected tag failure"
      end
    end
    environment = Liquid::Environment.build { |env| env.register_tag("audit_failure", tag) }
    context = Liquid::ParseContext.new(environment: environment)
    context.start_liquid_c_parsing
    body = Liquid::C::BlockBody.new(context)
    tokenizer = context.new_tokenizer("{% liquid audit_failure %}after", start_line_number: 1)
    assert_raises(RuntimeError) { body.parse(tokenizer, context) { |*| } }
    refute_predicate(tokenizer, :for_liquid_tag)
    assert_equal("after", tokenizer.shift)
  ensure
    context&.cleanup_liquid_c_parsing
  end

  def test_invalid_tag_diagnostics_use_the_whole_token
    ["{%%}", "{%- -%}", "{%%- %}"].each do |source|
      error = assert_raises(Liquid::SyntaxError) { Liquid::Template.parse(source) }
      assert_equal("Liquid syntax error: Unknown tag '#{source}'", error.message)
    end
  end

  def test_liquid_tokenizer_counts_the_final_line_without_a_newline
    ["echo x", "\necho x", "echo x\n", "\n\n", ""].each do |source|
      tokenizer = Liquid::C::Tokenizer.new(source, 1, true)
      source.split("\n").each_with_index do |line, index|
        assert_equal(line, tokenizer.shift)
        assert_equal(index + 2, tokenizer.line_number)
      end
      assert_nil(tokenizer.shift)
    end
  end

  def test_large_line_numbers_survive_tokenizing_compilation_and_rescue
    [(1 << 24) - 1, 1 << 24, 1 << 40, 1 << 100].each do |start|
      context = Liquid::ParseContext.new(error_mode: :strict)
      context.start_liquid_c_parsing
      body = Liquid::C::BlockBody.new(context)
      body.parse(context.new_tokenizer("\n{{ missing }}", start_line_number: start), context) { |*| }
      body.freeze
      context.cleanup_liquid_c_parsing
      assert_includes(body.disassemble, "line_number: #{start + 1}")
      render_context = Liquid::Context.new
      render_context.strict_variables = true
      body.render_to_output_buffer(render_context, +"")
      assert_equal(start + 1, render_context.errors.first.line_number)
      assert_equal(start + 1, body.nodelist.last.line_number)
    end
  end

  def test_negative_int16_boundaries
    [-32768, -32767, -256, -129, -128, 0, 32767].each do |number|
      assert_equal(number, Liquid::C::Expression.strict_parse("(#{number}..1)").begin)
      expression = Liquid::C::Expression.strict_parse("(#{number}..last)")
      assert_equal(number, expression.evaluate(Liquid::Context.new("last" => 1)).begin)
      assert_equal(number.to_s, Liquid::Template.parse("{{ #{number} }}").render!)
      context = Liquid::Context.new("value" => number)
      assert_equal(number, Liquid::C::Expression.strict_parse("value").evaluate(context))
    end
  end

  def test_raw_embedded_string_survives_compaction_in_blank_callback
    skip("GC compaction is unavailable") unless GC.respond_to?(:verify_compaction_references)
    return isolate(__method__) unless ENV["LIQUID_AUDIT_CASE"] == __method__.to_s

    before = GC.stat(:total_moved_objects)
    original = Liquid::Raw.instance_method(:blank?)
    Liquid::Raw.define_method(:blank?) do
      GC.verify_compaction_references(expand_heap: true, toward: :empty)
      false
    end
    ["", "x", "x" * 23, "x" * 24, "é" * 11].each do |text|
      assert_equal(text, Liquid::Template.parse("{% raw %}#{text}{% endraw %}").render!)
    end
    assert_operator(GC.stat(:total_moved_objects), :>, before)
  ensure
    Liquid::Raw.define_method(:blank?, original) if original
  end

  def test_expression_source_is_pinned_across_conversion_callbacks
    skip("GC compaction is unavailable") unless GC.respond_to?(:verify_compaction_references)
    return isolate(__method__) unless ENV["LIQUID_AUDIT_CASE"] == __method__.to_s

    before = GC.stat(:total_moved_objects)
    original = Integer.instance_method(:to_i)
    Integer.define_method(:to_i) do
      GC.verify_compaction_references(expand_heap: true, toward: :empty)
      original.bind_call(self)
    end
    assert_equal(1..3, Liquid::C::Expression.strict_parse("(1..3)"))
    assert_operator(GC.stat(:total_moved_objects), :>, before)
  ensure
    Integer.define_method(:to_i, original) if original
  end

  def test_deep_native_parsers_raise_without_a_signal
    if ENV["RUBY_MEMCHECK_LOADED_FEATURES_FILE"]
      skip("Valgrind intercepts intentional stack exhaustion before MRI's signal handler")
    end

    code = <<~RUBY
      $LOAD_PATH.unshift(ENV["LIQUID_C_EXTENSION_DIR"]) if ENV["LIQUID_C_EXTENSION_DIR"]
      require "liquid/c"
      [-> { Liquid::C::Expression.strict_parse("x[" * 500_000 + "x" + "]" * 500_000) },
       -> { Liquid::C::Expression.strict_parse("(" * 500_000 + "1" + "..1)" * 500_000) },
       -> { Liquid::Template.parse("{% " + "liquid " * 500_000 + "%}") }].each do |parse|
        begin
          parse.call
          abort "expected SystemStackError"
        rescue SystemStackError
          print "ok "
        end
      end
      print Liquid::Template.parse("ok").render!
    RUBY
    log = "tmp/audit/deep-#{Process.pid}.log"
    command = [RbConfig.ruby, "-Ilib", "-e", code]
    spawn_options = { rlimit_stack: 8 * 1024 * 1024 }
    if RUBY_ENGINE == "truffleruby"
      command = ["sh", "-c", 'ulimit -s 8192 && exec "$@"', "liquid-c-stack", *command]
      spawn_options = {}
    end
    result = Compatibility::ProcessRunner.run(
      command,
      env: {},
      log: log,
      timeout: 60,
      spawn_options: spawn_options,
    )
    assert(result[:success], "#{result.inspect}\n#{File.read(log)}")
    assert_equal("ok ok ok ok", File.read(log))
  end

  private

  # Aggressive heap expansion must not affect a later GC.stress test in the
  # same MRI process (including on the unmodified extension).
  def isolate(name)
    log = "tmp/audit/#{name}-#{Process.pid}.log"
    result = Compatibility::ProcessRunner.run(
      [RbConfig.ruby, "-Ilib", "-Itest", __FILE__, "--name", name.to_s],
      env: { "LIQUID_AUDIT_CASE" => name.to_s },
      log: log,
      timeout: 60,
    )
    assert(result[:success], File.read(log))
  end
end
