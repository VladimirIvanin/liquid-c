# frozen_string_literal: true

namespace :test do
  integration_test_config = lambda do |task|
    task.libs << "lib"
    task.test_files = ["test/integration_test.rb"]
  end

  desc "Run upstream integration tests with the selected engine and parser"
  Rake::TestTask.new(integration: :compile, &integration_test_config)

  namespace :integration do
    ["lax", "warn", "strict", "strict2"].each do |mode|
      task mode => :compile do
        sh(
          { "LIQUID_ENGINE" => "c", "LIQUID_PARSER_MODE" => mode, "LIQUID_C_DISABLE_VM" => nil },
          RbConfig.ruby,
          "-Ilib",
          "test/integration_test.rb",
        )
      end
    end

    task without_vm: :compile do
      sh(
        { "LIQUID_ENGINE" => "no_vm", "LIQUID_PARSER_MODE" => "strict", "LIQUID_C_DISABLE_VM" => nil },
        RbConfig.ruby,
        "-Ilib",
        "test/integration_test.rb",
      )
    end

    task all: :compile do
      results = ["lax", "warn", "strict", "strict2"].map do |mode|
        system(
          { "LIQUID_ENGINE" => "c", "LIQUID_PARSER_MODE" => mode, "LIQUID_C_DISABLE_VM" => nil },
          RbConfig.ruby,
          "-Ilib",
          "test/integration_test.rb",
        )
      end
      results << system(
        { "LIQUID_ENGINE" => "no_vm", "LIQUID_PARSER_MODE" => "strict", "LIQUID_C_DISABLE_VM" => nil },
        RbConfig.ruby,
        "-Ilib",
        "test/integration_test.rb",
      )
      abort("Integration failures") unless results.all?
    end

    RubyMemcheck::TestTask.new(valgrind: :compile, &integration_test_config)
    namespace :valgrind do
      configurations = ["lax", "warn", "strict", "strict2"].map { |mode| [mode, "c", mode] }
      configurations << ["without_vm", "no_vm", "strict"]
      configurations.each do |name, engine, mode|
        task name => :compile do
          sh(
            { "LIQUID_ENGINE" => engine, "LIQUID_PARSER_MODE" => mode, "LIQUID_C_DISABLE_VM" => nil },
            RbConfig.ruby,
            "-S",
            "rake",
            "test:integration:valgrind",
          )
        end
      end

      task all: :compile do
        results = configurations.map do |_name, engine, mode|
          system(
            { "LIQUID_ENGINE" => engine, "LIQUID_PARSER_MODE" => mode, "LIQUID_C_DISABLE_VM" => nil },
            RbConfig.ruby,
            "-S",
            "rake",
            "test:integration:valgrind",
          )
        end
        abort("Valgrind integration failures") unless results.all?
      end
    end
  end
end
