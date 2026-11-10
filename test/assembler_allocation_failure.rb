# frozen_string_literal: true

# Run against a separate build configured with LIQUID_C_TEST_ALLOC_FAILURES=true.
require "bundler/setup"
$LOAD_PATH.unshift(ENV.fetch("LIQUID_C_EXTENSION_DIR"))
require "liquid/c"
abort "test allocation hooks are absent" unless Liquid::C.respond_to?(:test_fail_assembler_allocation)

100.times do
  [3, 4].each do |count|
    count.times do |after|
      context = Liquid::ParseContext.new
      context.start_liquid_c_parsing if count == 4
      Liquid::C.test_fail_assembler_allocation(after)
      begin
        count == 3 ? Liquid::C::Expression.strict_parse("value") : Liquid::C::BlockBody.new(context)
        abort("allocation #{after}/#{count} did not fail")
      rescue NoMemoryError
        # The partially constructed TypedData must remain safe for GC/free.
      ensure
        Liquid::C.test_fail_assembler_allocation(-1)
      end
      GC.start
    end
  end
end
raise "failed to recover" unless Liquid::Template.parse("{{ value }}").render!("value" => "ok") == "ok"

source = "{% capture result %}{% if value %}{{ value | append: '!' }}" \
  "{% else %}empty{% endif %}{% endcapture %}{{ result }}" * 8
failures = 0
128.times do |after|
  Liquid::C.test_fail_assembler_allocation(after)
  begin
    template = Liquid::Template.parse(source, error_mode: :warn, line_numbers: true)
    raise "incorrect recovery output" unless template.render!("value" => "ok") == "ok!" * 8

    nodes = template.root.nodelist
    raise "missing recovery AST" if nodes.empty?
  rescue NoMemoryError
    failures += 1
  ensure
    Liquid::C.test_fail_assembler_allocation(-1)
  end
  GC.start
end
raise "native allocation paths were not exercised" if failures <= 10
raise "failed to recover native compilation" unless Liquid::Template.parse(
  source,
  error_mode: :warn,
).render!("value" => "ok") == "ok!" * 8

[0, 1].each do |after|
  context = Liquid::ParseContext.new
  context.start_liquid_c_parsing
  first = Liquid::C::BlockBody.new(context)
  first.parse(context.new_tokenizer("first"), context) { |*| }
  first.freeze
  second = Liquid::C::BlockBody.new(context)
  second.parse(context.new_tokenizer("second"), context) { |*| }
  Liquid::C.test_fail_assembler_allocation(after)
  begin
    second.freeze
    abort("document write checkpoint #{after} did not fail")
  rescue NoMemoryError
    # The failed write must leave the logical document unchanged for retry.
  ensure
    Liquid::C.test_fail_assembler_allocation(-1)
  end
  second.freeze
  context.cleanup_liquid_c_parsing
  render_context = Liquid::Context.new
  raise "first body changed after failed write" unless first.render_to_output_buffer(render_context, +"") == "first"
  raise "failed document write was not retryable" unless second.render_to_output_buffer(render_context, +"") == "second"
end

puts "#{700 + failures} injected allocation failures recovered"
