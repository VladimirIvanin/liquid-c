# frozen_string_literal: true

ext_task = Rake::ExtensionTask.new("liquid_c")

# For MacOS, generate debug information that ruby can read
dsymutil = RbConfig::CONFIG["dsymutil"]
unless dsymutil.to_s.empty?
  ext_lib_path = "lib/#{ext_task.binary}"
  dsym_path = "#{ext_lib_path}.dSYM"

  file dsym_path => [ext_lib_path] do
    sh dsymutil, ext_lib_path
  end
  Rake::Task["compile"].enhance([dsym_path])
end

# lib/liquid_c.so is shared by every Ruby, while rake-compiler builds in a
# per-version directory. Drop the copy when the Ruby changes so a binary built
# for another Ruby is never loaded.
abi_stamp = "tmp/liquid_c_ruby_abi"
current_abi = [RUBY_ENGINE, RbConfig::CONFIG["ruby_version"], RUBY_PLATFORM, RbConfig::CONFIG["host_os"]].join(" ")
desc "Remove lib/liquid_c.so when it was built by a different Ruby"
task :liquid_c_abi_stamp do
  previous = File.exist?(abi_stamp) ? File.read(abi_stamp) : nil
  if previous != current_abi
    rm_f "lib/#{ext_task.binary}"
    mkdir_p File.dirname(abi_stamp)
    File.write(abi_stamp, current_abi)
  end
end
Rake::Task["compile"].prerequisites.unshift("liquid_c_abi_stamp")
