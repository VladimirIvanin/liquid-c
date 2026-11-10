# frozen_string_literal: true

if Liquid::C.respond_to?(:native_register_compiler)
  Liquid::If.class_eval do
    private

    def liquid_c_finish_parse
      @blocks.reverse_each do |block|
        block.attachment.remove_blank_strings if blank?
        block.attachment.freeze
      end
    end
  end
  Liquid::For.class_eval do
    private

    def liquid_c_finish_parse
      if blank?
        @else_block&.remove_blank_strings
        @for_block.remove_blank_strings
      end
      @else_block&.freeze
      @for_block.freeze
    end
  end
  source_root = File.join(Gem.loaded_specs.fetch("liquid").full_gem_path, "lib", "liquid")
  library_root = File.expand_path("..", __dir__)
  context_method = Liquid::ParserSwitching.instance_method(:strict2_parse_with_error_context)
  expected_context_owner = context_method.owner == Liquid::ParserSwitching
  if expected_context_owner && context_method.original_name == :strict2_parse_with_error_context &&
      context_method.source_location&.first == File.join(source_root, "parser_switching.rb")
    Liquid::C.native_install_compiler_context
  end
  specifications = {
    Liquid::Variable.singleton_class => [:c_parse],
    Liquid::C::BlockBody.singleton_class => [:new, :allocate],
    Liquid::Condition.singleton_class => [:new, :allocate, :parse_expression],
    Liquid::ElseCondition.singleton_class => [:new, :allocate],
    Liquid::Variable => [
      :initialize,
      :strict_parse,
      :lax_parse,
      :c_compilable?,
      :compile_evaluate,
      :filters,
      :strict_parse_with_error_mode_fallback,
      :strict_parse_with_error_context,
      :strict2_mode?,
    ],
    Liquid::ParseContext => [:line_number, :depth, :depth=, :new_block_body, :environment],
    Liquid::Tag => [:initialize, :parse, :parse_context, :line_number, :options],
    Liquid::Tag.singleton_class => [:parse],
    Liquid::Block => [:initialize, :new_body, :parse_body, :block_name, :block_delimiter, :blank?],
    Liquid::Assign => [:initialize, :parse, :strict_parse, :strict2_parse, :lax_parse, :blank?],
    Liquid::Assign.singleton_class => [:parse],
    Liquid::Capture => [
      :initialize, :parse, :strict_parse, :strict2_parse, :lax_parse, :blank?, :unknown_tag, :raise_tag_never_closed,
    ],
    Liquid::Capture.singleton_class => [:parse],
    Liquid::Include => [
      :initialize, :parse, :strict_parse, :strict2_parse, :lax_parse, :blank?, :safe_parse_expression, :parse_context,
    ],
    Liquid::Include.singleton_class => [:parse],
    Liquid::If => [
      :initialize,
      :parse,
      :push_block,
      :unknown_tag,
      :strict_parse,
      :strict2_parse,
      :parse_binary_comparisons,
      :parse_comparison,
      :parse_expression,
    ],
    Liquid::Unless => [
      :initialize,
      :parse,
      :push_block,
      :unknown_tag,
      :strict_parse,
      :strict2_parse,
      :parse_binary_comparisons,
      :parse_comparison,
      :parse_expression,
    ],
    Liquid::For => [
      :initialize,
      :parse,
      :unknown_tag,
      :strict_parse,
      :strict2_parse,
      :set_attribute,
      :parse_expression,
    ],
    Liquid::If.singleton_class => [:parse],
    Liquid::Unless.singleton_class => [:parse],
    Liquid::For.singleton_class => [:parse],
    Liquid::Condition => [:initialize, :and, :or, :attach, :attachment],
    Liquid::ElseCondition => [:initialize, :attach, :attachment],
    Liquid::Environment => [:tag_for_name],
    Liquid::ParserSwitching => [:strict2_parse_with_error_context],
    Liquid::VariableLookup => [:compile_evaluate, :name, :lookups],
    Liquid::RangeLookup => [:compile_evaluate],
    Liquid::C::BlockBody => [
      :add_evaluate_expression,
      :add_find_variable,
      :add_lookup_guard,
      :patch_lookup_guard,
      :add_lookup_command,
      :add_lookup_key,
      :add_new_int_range,
      :add_hash_new,
      :add_filter,
      :initialize,
      :parse,
      :freeze,
      :remove_blank_strings,
      :blank?,
    ],
  }
  switching = [:parse_with_selected_parser, :strict_parse_with_error_context, :strict2_parse_with_error_context]
  inherited = [:new_body, :parse_body, :block_name, :block_delimiter, :blank?, :parse_context, :line_number, :options]
  [Liquid::If, Liquid::Unless, Liquid::For].each { |klass| specifications[klass].concat(inherited + switching) }
  specifications[Liquid::Include].concat(switching + [:line_number, :options])
  specifications[Liquid::Capture].concat((inherited + switching).reject { |name| name == :blank? })
  specifications[Liquid::Assign].concat(switching)
  standard = Liquid::C::NativeParser::NATIVE_GUARDS
  standard &&= Liquid::Tag.method(:new).unbind == Class.instance_method(:new)
  control_owners = [
    Liquid::Assign,
    Liquid::Assign.singleton_class,
    Liquid::Capture,
    Liquid::Capture.singleton_class,
    Liquid::Include,
    Liquid::Include.singleton_class,
    Liquid::Tag,
    Liquid::Tag.singleton_class,
    Liquid::Block,
    Liquid::If,
    Liquid::Unless,
    Liquid::For,
    Liquid::If.singleton_class,
    Liquid::Unless.singleton_class,
    Liquid::For.singleton_class,
    Liquid::Condition,
    Liquid::Condition.singleton_class,
    Liquid::ElseCondition,
    Liquid::ElseCondition.singleton_class,
    Liquid::C::BlockBody.singleton_class,
  ]
  guards = specifications.flat_map do |owner, names|
    names.map do |name|
      method = owner.instance_method(name)
      location = method.source_location&.first
      builtin_constructor = [:new, :allocate].include?(name) &&
        [
          Liquid::C::BlockBody.singleton_class,
          Liquid::Condition.singleton_class,
          Liquid::ElseCondition.singleton_class,
        ].include?(owner)
      expected_owner = if builtin_constructor
        Class
      elsif (switching + [:strict_parse_with_error_mode_fallback, :strict2_mode?]).include?(name)
        Liquid::ParserSwitching
      elsif inherited.include?(name) && [Liquid::If, Liquid::Unless, Liquid::For].include?(owner)
        [:parse_context, :line_number, :options].include?(name) ? Liquid::Tag : Liquid::Block
      elsif owner == Liquid::Include && [:blank?, :safe_parse_expression, :line_number, :options].include?(name)
        Liquid::Tag
      elsif owner == Liquid::Capture && [:parse, :unknown_tag, :raise_tag_never_closed].include?(name)
        Liquid::Block
      elsif owner == Liquid::Capture && inherited.include?(name) && name != :blank?
        [:parse_context, :line_number, :options].include?(name) ? Liquid::Tag : Liquid::Block
      elsif owner == Liquid::Assign && name == :parse
        Liquid::Tag
      elsif owner == Liquid::Unless
        Liquid::If
      elsif owner == Liquid::For && name == :parse_expression
        Liquid::Tag
      elsif owner == Liquid::ElseCondition
        Liquid::Condition
      elsif [
        Liquid::If.singleton_class,
        Liquid::Unless.singleton_class,
        Liquid::For.singleton_class,
        Liquid::Assign.singleton_class,
        Liquid::Capture.singleton_class,
        Liquid::Include.singleton_class,
      ].include?(owner)
        Liquid::Tag.singleton_class
      else
        owner
      end
      expected_name = name == :options ? :parse_context : name
      standard &&= method.owner == expected_owner && method.original_name == expected_name &&
        (if owner == Liquid::C::BlockBody || builtin_constructor || [
          :strict_parse_with_error_context,
          :strict2_parse_with_error_context,
        ].include?(name)
           location.nil?
         else
           location && (location.start_with?(source_root + "/") || location.start_with?(library_root + "/"))
         end)
      control = control_owners.include?(owner) ||
        owner == Liquid::ParseContext && [:depth, :depth=, :new_block_body].include?(name) ||
        owner == Liquid::C::BlockBody && [:initialize, :parse, :freeze, :remove_blank_strings, :blank?].include?(name)
      [owner, name, control].freeze
    end
  end
  constants = [
    *[
      :Block, :Tag, :If, :For, :Unless, :Condition, :ElseCondition, :Environment, :Assign, :Capture, :Include,
    ].map do |name|
      [Liquid, name]
    end,
    [Liquid::Assign, :Syntax],
    [Liquid::Include, :FOR],
    [Liquid::Block, :MAX_DEPTH],
    [Liquid::If, :ELSE_TAG_NAMES],
    [Liquid::C, :BlockBody],
  ].map do |owner, name|
    location = owner.const_source_location(name)&.first
    native_class = owner == Liquid::C && name == :BlockBody &&
      $LOADED_FEATURES.any? { |path| path == location && path.end_with?("/liquid_c.so", "/liquid_c.bundle") }
    standard &&= native_class || location && location.start_with?(source_root + "/", library_root + "/")
    [owner, name, owner.const_get(name, false)].freeze
  end.freeze
  ancestor_prefixes = [
    [Liquid::Assign, [Liquid::Assign, Liquid::Tag]],
    [Liquid::Capture, [Liquid::Capture, Liquid::Block, Liquid::Tag]],
    [Liquid::Include, [Liquid::Tag::Disableable, Liquid::Include, Liquid::Tag]],
    [Liquid::If, [Liquid::If, Liquid::Block, Liquid::Tag]],
    [Liquid::Unless, [Liquid::Unless, Liquid::If, Liquid::Block, Liquid::Tag]],
    [Liquid::For, [Liquid::For, Liquid::Block, Liquid::Tag]],
    [Liquid::C::BlockBody, [Liquid::C::BlockBody, Object]],
  ].map do |klass, prefix|
    standard &&= klass.ancestors.first(prefix.size) == prefix
    prefix = klass.ancestors
    [klass, prefix.freeze].freeze
  end.freeze
  constant_watchers = if Liquid::C::NativeParser::CONSTANT_WATCHERS
    evaluator = Module.instance_method(:module_eval)
    constants.map do |owner, name, expected|
      reader = evaluator.bind_call(owner, "-> { #{name} }", __FILE__, __LINE__)
      standard &&= reader.call.equal?(expected)
      reader.freeze
    end.freeze
  end
  Liquid::C.native_register_control(
    [Liquid::If.instance_method(:liquid_c_finish_parse), Liquid::For.instance_method(:liquid_c_finish_parse)].freeze,
    constants,
    ancestor_prefixes,
    constant_watchers,
  )
  [:render, :render_to_output_buffer, :render_obj_to_output].each do |name|
    method = Liquid::Variable.instance_method(name)
    standard &&= method.owner == Liquid::Variable && method.source_location.nil? && method.original_name == :"c_#{name}"
  end
  Liquid::C.native_register_compiler(guards.freeze, standard)

end

Liquid::C.private_constant(:VariablePlaceholder)
