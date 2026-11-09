# frozen_string_literal: true

require "optparse"
require "fileutils"
require "open3"
require "json"
require "digest"
require "rbconfig"

options = { baseline: "6d66f63", output: "tmp/cross-engines" }
OptionParser.new do |parser|
  parser.banner = "usage: build_cross_engines.rb --liquid4 PATH --liquid-c4 PATH --liquid5 PATH [options]"
  [:liquid4, :liquid_c4, :liquid5, :baseline, :output].each do |name|
    parser.on("--#{name.to_s.tr("_", "-")} VALUE") { |value| options[name] = value }
  end
end.parse!
[:liquid4, :liquid_c4, :liquid5].each { |name| abort "missing --#{name.to_s.tr("_", "-")}" unless options[name] }
root = File.expand_path("..", __dir__)
output = File.expand_path(options.fetch(:output))
FileUtils.mkdir_p(output)
run = lambda do |*command|
  stdout, stderr, status = Open3.capture3(*command, chdir: root)
  abort("#{command.inspect}: #{stderr}") unless status.success?
  stdout
end
current_sha = run.call("git", "rev-parse", "HEAD").strip
baseline_sha = run.call("git", "rev-parse", options.fetch(:baseline)).strip
snapshots = {}
{ "baseline" => baseline_sha, "current" => current_sha }.each do |name, revision|
  destination = File.join(output, name)
  abort "snapshot already exists: #{destination}" if File.exist?(destination)
  FileUtils.mkdir_p(destination)
  if name == "current"
    files = run.call(
      "git",
      "ls-files",
      "-z",
      "--cached",
      "--others",
      "--exclude-standard",
      "--",
      "ext",
      "lib",
    ).split("\0")
    files.each do |file|
      next unless File.file?(File.join(root, file))
      next if file.end_with?(".so", ".bundle", ".o")

      FileUtils.mkdir_p(File.join(destination, File.dirname(file)))
      FileUtils.cp(File.join(root, file), File.join(destination, file))
    end
  else
    archive = run.call("git", "archive", revision, "--", "ext", "lib")
    _stdout, stderr, status = Open3.capture3("tar", "xf", "-", "-C", destination, stdin_data: archive, binmode: true)
    abort stderr unless status.success?
  end
  snapshots[name] = destination
end

source_digest = lambda do |directory|
  digest = Digest::SHA256.new
  Dir.glob(File.join(directory, "{ext,lib}", "**", "*"), File::FNM_EXTGLOB).sort.each do |file|
    next unless File.file?(file)
    next if file.end_with?(".so", ".bundle", ".o")

    digest << file.delete_prefix(directory + "/") << "\0" << File.binread(file) << "\0"
  end
  digest.hexdigest
end
build = lambda do |directory, sources, pedantic|
  FileUtils.mkdir_p(directory)
  log = File.join(directory, "build.log")
  File.open(log, "w") do |file|
    env = { "DEBUG" => "false", "LIQUID_C_PEDANTIC" => pedantic ? "true" : nil, "LIQUID_C_TEST_ALLOC_FAILURES" => nil }
    commands = [[RbConfig.ruby, File.join(sources, "ext/liquid_c/extconf.rb")], ["make", "-j2"]]
    commands.each do |command|
      abort("build failed: #{log}") unless system(env, *command, chdir: directory, out: file, err: file)
    end
  end
end
configurations = [
  {
    "name" => "legacy",
    "liquid_root" => File.expand_path(options.fetch(:liquid4)),
    "library" => File.join(File.expand_path(options.fetch(:liquid_c4)), "lib"),
    "source_root" => File.expand_path(options.fetch(:liquid_c4)),
    "expected_liquid" => "4.0.4",
    "expected_liquid_c" => "4.0.1",
  },
  {
    "name" => "pure",
    "liquid_root" => File.expand_path(options.fetch(:liquid5)),
    "expected_liquid" => "5.14.0",
  },
]
snapshots.each do |name, directory|
  configurations << {
    "name" => name,
    "liquid_root" => File.expand_path(options.fetch(:liquid5)),
    "library" => File.join(directory, "lib"),
    "source_root" => directory,
    "revision" => name == "current" ? current_sha : baseline_sha,
    "expected_liquid" => "5.14.0",
  }
end
configurations.each do |configuration|
  configuration["liquid_source_sha256"] = source_digest.call(configuration.fetch("liquid_root"))
  next unless configuration["library"]

  sources = configuration.fetch("source_root")
  configuration["source_sha256"] = source_digest.call(sources)
  configuration["extension"] = File.join(output, "#{configuration.fetch("name")}-build")
  build.call(configuration.fetch("extension"), sources, configuration.fetch("name") != "legacy")
  puts "#{configuration.fetch("name")}: built"
end
manifest = File.join(output, "engines.json")
File.write(manifest, JSON.pretty_generate(configurations) + "\n")
puts manifest
