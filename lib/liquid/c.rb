# frozen_string_literal: true

require "liquid/c/version"
require "liquid"
require "liquid_c"
require "liquid/c/compile_ext"

Liquid::C::BlockBody.class_eval do
  def render(context)
    render_to_output_buffer(context, +"")
  end
end

module Liquid
  BlockBody.class_eval do
    class << self
      def c_rescue_render_node(context, output, line_number, exc, blank_tag)
        # There seems to be a MRI ruby bug with how the rb_rescue C function,
        # where $! gets set for its rescue callback, but it doesn't stay set
        # after a nested exception is raised and handled as is the case in
        # Liquid::Context#internal_error. This isn't a problem for plain ruby code,
        # so use a ruby rescue block to have setup $! properly.
        raise(exc)
      rescue => exc
        rescue_render_node(context, output, line_number, exc, blank_tag)
      end
    end
  end
end

module Liquid
  module C
    class Tokenizer
      MAX_SOURCE_BYTE_SIZE = (1 << 24) - 1
    end
  end
end

Liquid::Raw.class_eval do
  alias_method :ruby_parse, :parse

  def parse(tokenizer)
    if parse_context.liquid_c_nodes_disabled?
      ruby_parse(tokenizer)
    else
      c_parse(tokenizer)
    end
  end
end

module Liquid
  module C
    module CaseDiscardedBody
      def parse(tokens)
        @c_case_track_first_body = true
        super
      ensure
        @c_case_track_first_body = false
        @c_case_first_body = nil
      end

      def unknown_tag(tag, markup, tokens)
        if (tag == "when" || tag == "else") && @c_case_first_body
          @c_case_first_body.send(:discard_unreachable)
          @c_case_first_body = nil
        end
        super
      end

      private

      def new_body
        body = super
        if @c_case_track_first_body
          @c_case_track_first_body = false
          if body.is_a?(Liquid::C::BlockBody)
            body.send(:mark_discardable)
            @c_case_first_body = body
          end
        end
        body
      end
    end
  end
end
Liquid::Case.prepend(Liquid::C::CaseDiscardedBody)

Liquid::ParseContext.class_eval do
  class << self
    attr_accessor :liquid_c_nodes_disabled
  end
  self.liquid_c_nodes_disabled = false

  alias_method :ruby_new_block_body, :new_block_body

  def new_block_body
    if liquid_c_nodes_disabled?
      ruby_new_block_body
    else
      Liquid::C::BlockBody.new(self)
    end
  end

  alias_method :ruby_new_tokenizer, :new_tokenizer
  def new_tokenizer(source, start_line_number: nil, for_liquid_tag: false)
    unless liquid_c_nodes_disabled?
      source = source.to_s.to_str
      encoded_source = source.encode(Encoding::UTF_8)
      if encoded_source.bytesize <= Liquid::C::Tokenizer::MAX_SOURCE_BYTE_SIZE
        return Liquid::C::Tokenizer.new(encoded_source, start_line_number || 0, for_liquid_tag)
      else
        @liquid_c_nodes_disabled = true
      end
    end

    ruby_new_tokenizer(source, start_line_number: start_line_number, for_liquid_tag: for_liquid_tag)
  end

  # @api private
  def liquid_c_nodes_disabled?
    # Liquid::Profiler exposes the internal parse tree that we don't want to build when
    # parsing with liquid-c, so consider liquid-c to be disabled when using it.
    # Also, some templates are parsed before the profiler is running, on which case we
    # provide the `disable_liquid_c_nodes` option to enable the Ruby AST to be produced
    # so the profiler can use it on future runs.
    return @liquid_c_nodes_disabled if defined?(@liquid_c_nodes_disabled)

    @liquid_c_nodes_disabled = !Liquid::C.enabled || @template_options[:profile] ||
      @template_options[:disable_liquid_c_nodes] || self.class.liquid_c_nodes_disabled
  end
end

module Liquid
  module C
    module DocumentClassPatch
      def parse(tokenizer, parse_context)
        if tokenizer.is_a?(Liquid::C::Tokenizer)
          if parse_context[:bug_compatible_whitespace_trimming]
            # Temporary to test rollout of the fix for this bug
            tokenizer.bug_compatible_whitespace_trimming!
          end

          begin
            parse_context.start_liquid_c_parsing
            super
          ensure
            parse_context.cleanup_liquid_c_parsing
          end
        else
          super
        end
      end
    end
    Liquid::Document.singleton_class.prepend(DocumentClassPatch)
  end
end

Liquid::Variable.class_eval do
  output_methods = [:render, :render_to_output_buffer, :render_obj_to_output]
  source = File.join(Gem.loaded_specs.fetch("liquid").full_gem_path, "lib/liquid/variable.rb")
  Liquid::C::VARIABLE_RENDERERS = output_methods.filter_map do |name|
    original = instance_method(name)
    original = original.super_method while original && original.owner != self
    next unless original&.source_location&.first == source

    define_method(:"ruby_#{name}", original)
    [name, original, instance_method(:"c_#{name}")]
  end.freeze

  class << self
    def c_parse(markup, parse_context)
      if /\A\s*-\.\d/.match?(markup)
        Liquid::Usage.increment("liquid_c_negative_float_without_integer")
      end
      new(markup, parse_context)
    end
  end

  alias_method :ruby_strict_parse, :strict_parse

  def strict_parse(markup)
    result = liquid_c_native_parse(markup)
    if result
      @name, @filters = result
      nil
    else
      ruby_strict_parse(markup)
    end
  rescue Liquid::SyntaxError
    if !parse_context.liquid_c_nodes_disabled? && [:lax, :warn].include?(parse_context.error_mode)
      self.class.call_variable_fallback_stats_callback(parse_context)
    end
    raise
  end

  def c_compilable?
    filters.all? do |_name, args, kwargs|
      args.size + (kwargs ? 1 : 0) <= 254 && (!kwargs || kwargs.size <= 255)
    end
  end

  class << self
    # @api private
    def call_variable_fallback_stats_callback(parse_context)
      callbacks = parse_context[:stats_callbacks]
      callbacks[:variable_fallback]&.call if callbacks
    end
  end
end

Liquid::StrainerTemplate.class_eval do
  class << self
    original = instance_method(:add_filter)
    original = original.super_method while original.owner != self
    define_method(:ruby_add_filter, original)

    def add_filter(filter)
      result = ruby_add_filter(filter)
      @filter_methods_hash&.replace(filter_methods.to_h { |name| [name.to_sym, true] })
      result
    end

    private

    def filter_methods_hash
      @filter_methods_hash ||= {}.tap do |hash|
        filter_methods.each do |method_name|
          hash[method_name.to_sym] = true
        end
      end
    end

    # Convert wrong number of argument error into a liquid exception to
    # treat it as an error in the template, not an internal error.
    def arg_exc_to_liquid_exc(argument_error)
      raise Liquid::ArgumentError, argument_error.message, argument_error.backtrace
    rescue Liquid::ArgumentError => liquid_exc
      liquid_exc
    end
  end
end

Liquid::C::Expression.class_eval do
  class << self
    def lax_parse(markup)
      strict_parse(markup)
    rescue Liquid::SyntaxError
      Liquid::Expression.parse(markup)
    end

    # Default to strict parsing, since Liquid::C::Expression.parse should only really
    # be used with constant expressions.  Otherwise, prefer parse_context.parse_expression.
    alias_method :parse, :strict_parse
  end
end

Liquid::Context.class_eval do
  native_methods = {
    :[] => :c_parse_evaluate,
    evaluate: :c_evaluate,
    find_variable: :c_find_variable_kwarg,
    :strict_variables= => :c_strict_variables=,
    :strict_filters= => :c_strict_filters=,
    :global_filter= => :c_global_filter=,
    add_filters: :c_add_filters,
  }
  source = File.join(Gem.loaded_specs.fetch("liquid").full_gem_path, "lib/liquid/context.rb")
  Liquid::C::CONTEXT_METHODS = native_methods.filter_map do |name, native_name|
    original = instance_method(name)
    original = original.super_method while original && original.owner != self
    ruby_name = name == :[] ? :ruby_parse_evaluate : :"ruby_#{name}"
    define_method(ruby_name, original)
    next unless original.source_location&.first == source

    [name, original, native_name]
  end.freeze

  # This isn't entered often by Ruby (most calls stay in C via VariableLookup#evaluate)
  # so the wrapper method isn't costly.
  def c_find_variable_kwarg(key, raise_on_not_found: true)
    c_find_variable(key, raise_on_not_found)
  end

  def c_parse_evaluate(expression)
    ruby_parse_evaluate(expression)
  end
end

module Liquid
  module C
    module ContextCopyPatch
      private

      def initialize_copy(other)
        result = super
        Liquid::C::VM.reset_context(self)
        result
      end
    end
  end
end
Liquid::Context.prepend(Liquid::C::ContextCopyPatch)

Liquid::ResourceLimits.class_eval do
  class << self
    def new(limits)
      if equal?(Liquid::ResourceLimits) && Liquid::C.enabled
        Liquid::C::ResourceLimits.new(
          limits[:render_length_limit],
          limits[:render_score_limit],
          limits[:assign_score_limit],
          limits[:cumulative_render_score_limit],
          limits[:cumulative_assign_score_limit],
        )
      else
        super
      end
    end
  end
end

module Liquid
  module C
    class << self
      attr_reader :enabled

      def enabled=(value)
        @enabled = value
        Liquid::C::VM.invalidate_contexts
        Liquid::C::VARIABLE_RENDERERS.each do |name, ruby_method, native_method|
          next if Liquid::Variable.frozen?

          current = Liquid::Variable.instance_method(name)
          current = current.super_method while current && current.owner != Liquid::Variable
          expected = value ? ruby_method : native_method
          if current == expected
            replacement = value ? :"c_#{name}" : :"ruby_#{name}"
            Liquid::Variable.alias_method(name, replacement)
          end
        end
        Liquid::C::CONTEXT_METHODS.each do |name, ruby_method, native_name|
          next if Liquid::Context.frozen?
          # These setters must keep the hidden VM in sync even while rendering
          # falls back to Ruby, so it can release references immediately.
          next if !value && (name == :global_filter= || name == :add_filters)

          current = Liquid::Context.instance_method(name)
          current = current.super_method while current && current.owner != Liquid::Context
          native_method = Liquid::Context.instance_method(native_name)
          expected = value ? ruby_method : native_method
          next unless current == expected

          replacement = value ? native_method : ruby_method
          Liquid::Context.define_method(name, replacement)
        end
      end
    end

    self.enabled = true
  end
end

require "liquid/c/native_parser"
require "liquid/c/native_tags"
require "liquid/c/native_values"

# Parsing during require retains the original path until guards are ready.
Liquid::C.native_enable_variable_frontend
require "liquid/c/native_compiler"
