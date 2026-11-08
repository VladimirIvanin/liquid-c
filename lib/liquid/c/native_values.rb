# frozen_string_literal: true

if Liquid::C.respond_to?(:native_register_identity_methods)
  source = File.join(Gem.loaded_specs.fetch("liquid").full_gem_path, "lib", "liquid", "extensions.rb")
  flags = [String, Array, Hash, Numeric, Range, TrueClass, FalseClass, NilClass].map do |klass|
    ENV["LIQUID_C_IDENTITY_VALUES"] != "false" && klass.instance_method(:to_liquid).source_location&.first == source
  end
  Liquid::C.native_register_identity_methods(flags)
end
