# frozen_string_literal: true

require "fileutils"
require "open3"
require "rbconfig"
require "json"
require "digest"

# Build the safety + memchr stage, without the new parser/tag/value frontends.
# Run from the repository root with the Ruby used for both benchmark variants.
abort "usage: build_stage_baseline.rb OUTPUT [BASE_REVISION]" unless (1..2).cover?(ARGV.size)
output = File.expand_path(ARGV.fetch(0))
abort "output must differ from the repository root" if output == Dir.pwd
revision = ARGV.fetch(1, "21c3d74")
source = File.join(output, "src")
FileUtils.mkdir_p(source)
Dir["ext/liquid_c/*.{c,h,rb}"].each do |path|
  next if ["native_parser.c", "native_value.c"].include?(File.basename(path))

  FileUtils.cp(path, source)
end
liquid_path = File.join(source, "liquid.c")
liquid = File.read(liquid_path)
["liquid_define_native_parser", "liquid_define_native_values"].each do |name|
  abort "missing init #{name}" unless liquid.sub!("    #{name}();\n", "")
end
File.write(liquid_path, liquid)
context_path = File.join(source, "context.h")
context = File.read(context_path)
abort "missing value guard" unless context.sub!(
  /#ifdef HAVE_RB_CALLABLE_METHOD_ENTRY\n.*?\n#endif/m,
  "#define liquid_value_to_liquid(value) rb_funcall((value), id_to_liquid, 0)",
)
File.write(context_path, context)
paths, error, status = Open3.capture3("git", "ls-tree", "-r", "--name-only", revision, "--", "lib")
abort error unless status.success?
paths.lines(chomp: true).each do |path|
  text, error, status = Open3.capture3("git", "show", "#{revision}:#{path}")
  abort error unless status.success?

  target = File.join(output, path)
  FileUtils.mkdir_p(File.dirname(target))
  File.binwrite(target, text)
end
Dir.chdir(output) do
  abort "configure failed" unless system({ "DEBUG" => "false" }, RbConfig.ruby, File.join(source, "extconf.rb"))
  abort "compile failed" unless system("make", "-j2")
end
File.write(File.join(output, "stage.json"), JSON.pretty_generate(
  ruby: RUBY_DESCRIPTION,
  base_ruby_library: revision,
  stage: "current safety fixes and memchr; original Ruby wrappers; no new parser/tag/value frontend",
  source_sha256: Dir[File.join(source, "*")].sort.to_h do |path|
    [File.basename(path), Digest::SHA256.file(path).hexdigest]
  end,
) + "\n")
