# frozen_string_literal: true

module Compatibility
  class FileSystem
    attr_reader :reads

    def initialize(partials = {})
      @partials = partials
      @reads = []
    end

    def read_template_file(name)
      @reads << name
      @partials.fetch(name)
    end
  end

  class ValueDrop < Liquid::Drop
    def initialize(value)
      super()
      @value = value
    end

    def to_liquid_value
      @value
    end

    def to_s
      @value.to_s
    end
  end

  class ContextDrop < Liquid::Drop
    attr_reader :events

    def initialize
      super
      @events = []
    end

    def context=(context)
      @events << "context"
      super
    end

    def to_liquid
      @events << (@context ? "liquid_with_context" : "liquid_without_context")
      self
    end

    def title
      @context["title"]
    end
  end

  class FailingDrop < Liquid::Drop
    def title
      raise Liquid::ArgumentError, "lookup failure"
    end
  end

  module Filters
    def probe(input, suffix = "!", options = {})
      "#{input}#{suffix}#{options.fetch("label", "")}"
    end

    def explode(_input)
      raise Liquid::ArgumentError, "probe failure"
    end

    def ruby_explode(_input)
      raise ArgumentError, "ruby probe failure"
    end

    def wrapped(input)
      ValueDrop.new(input)
    end
  end

  class MarkerTag < Liquid::Tag
    def render(context)
      context.registers[:calls] = context.registers.fetch(:calls, 0) + 1
      "[#{context["title"]}]"
    end
  end

  class BufferBlock < Liquid::Block
    def render_to_output_buffer(context, output)
      output << "<"
      super
      output << ">"
    end
  end
end
