# frozen_string_literal: true

require "bundler/setup"
$LOAD_PATH.unshift(ENV.fetch("LIQUID_C_LIBRARY_DIR")) if ENV["LIQUID_C_LIBRARY_DIR"]
$LOAD_PATH.unshift(ENV.fetch("LIQUID_C_EXTENSION_DIR")) if ENV["LIQUID_C_EXTENSION_DIR"]
require "liquid/c"

mode = ARGV.fetch(0, "all")
raise ArgumentError, mode unless ["all", "compaction", "stress"].include?(mode)

if mode != "stress"
  source = "{% for item in values %}{% if item.name %}{{ item.name | append: suffix }}" \
    "{% else %}empty{% endif %}{% endfor %}"
  assigns = { "values" => [{ "name" => "a" }, { "name" => "b" }], "suffix" => "!" }
  20.times do |iteration|
    template = Liquid::Template.parse(source, error_mode: :warn, line_numbers: true)
    GC.start
    if iteration.zero? && GC.respond_to?(:verify_compaction_references)
      GC.verify_compaction_references(toward: :empty)
    end
    raise "incorrect compiled output" unless template.render!(assigns) == "a!b!"

    loop_tag = template.root.nodelist.first
    condition = loop_tag.nodelist.first.nodelist.first
    variable = condition.blocks.first.attachment.nodelist.first
    filters = variable.filters
    filters.first.first.replace("prepend")
    filters << ["upcase", []]
    GC.start
    raise "materialization lost identity" unless variable.filters.equal?(filters)
    raise "incorrect materialized output" unless template.render!(assigns) == "!A!B"
  end

end

begin
  GC.stress = true unless mode == "compaction"
  (mode == "compaction" ? 0 : 2).times do
    template = Liquid::Template.parse("{% if value %}{{ value | append: '!' }}{% endif %}", error_mode: :warn)
    raise "incorrect stressed output" unless template.render!("value" => "ok") == "ok!"
    raise "missing stressed AST" if template.root.nodelist.empty?
  end
ensure
  GC.stress = false
end
puts "native compilation and #{mode} passed"
