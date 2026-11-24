# frozen_string_literal: true

desc "Check that every global VALUE in the C extension is a registered GC root"
task :gc_roots do
  ruby File.expand_path("../script/check-gc-roots", __dir__)
end
