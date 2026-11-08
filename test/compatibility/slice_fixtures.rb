# frozen_string_literal: true

module Compatibility
  class LazySliceDrop < Liquid::Drop
    attr_reader :events
    attr_accessor :forbid_each, :failure, :callback

    def initialize(values = ["a", "b", "c", "d"])
      super()
      @values = values
      @events = []
    end

    def each(&block)
      raise "Full collection loaded" if forbid_each

      @events << [:each, @context["prefix"]]
      @values.each(&block)
    end

    def load_slice(from, to)
      @events << [:load_slice, from, to, @context["prefix"]]
      raise Liquid::ArgumentError, "slice failed" if failure

      callback&.call(@context)
      # Model a repository query, including an open-ended upper bound. The
      # recorded arguments, rather than Array slicing, define the hook contract.
      @values.each_with_index.filter_map { |value, index| value if index >= from && (to.nil? || index < to) }
    end
  end

  module SlicePrefixPatch
    def load_slice(from, to)
      events << [:patch, from, to, @context["prefix"]]
      super.map { |value| "#{@context["prefix"]}:#{value}" }
    end
  end

  module SliceUtilsPatch
    def slice_collection(collection, from, to)
      return super unless collection.is_a?(LazySliceDrop)

      collection.load_slice(from, to)
    end
  end
end
