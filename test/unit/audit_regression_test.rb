# frozen_string_literal: true

require "test_helper"
require "rbconfig"
require_relative "../compatibility/process_runner"

class AuditRegressionTest < Minitest::Test
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
    result = Compatibility::ProcessRunner.run(
      [RbConfig.ruby, "-Ilib", "-e", code],
      env: {},
      log: log,
      timeout: 60,
      spawn_options: { rlimit_stack: 8 * 1024 * 1024 },
    )
    assert(result[:success], File.read(log))
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
