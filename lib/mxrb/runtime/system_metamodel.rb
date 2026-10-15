# frozen_string_literal: true

require 'json'

module Mxrb
  module Runtime
    # What the Mendix Runtime reports for its own System module through
    # Core.getMetaObjects, Core.getMetaAssociations and its microflow API, recorded
    # from the Runtime of each version with the native_metamodel oracle fixture
    # (script/extract_system_metamodel). A project gets the recording of the newest
    # version not newer than its own, or the oldest when it predates them all.
    module SystemMetamodel
      RECORDINGS = Dir.glob(File.join(__dir__, 'system_metamodel_*.json')).to_h do |path|
        [Gem::Version.new(File.basename(path, '.json').delete_prefix('system_metamodel_')), path]
      end.sort.to_h.freeze
      @loaded = {}
      @lock = Mutex.new

      module_function

      def for(mendix_version)
        version = Gem::Version.correct?(mendix_version.to_s) ? Gem::Version.new(mendix_version.to_s) : nil
        recorded = RECORDINGS.keys.reverse.find { version && _1 <= version } || RECORDINGS.keys.first
        @lock.synchronize { @loaded[recorded] ||= load(RECORDINGS.fetch(recorded)) }
      end

      # The values of each System enumeration, as the System primitives list them.
      def enumerations(mendix_version) = self.for(mendix_version).fetch('enumerations')

      def load(path)
        metamodel = JSON.parse(File.read(path))
        enumerations = metamodel.fetch('objects').flat_map { _1.fetch('primitives') }.select { _1.key?('enum') }
        metamodel['enumerations'] = enumerations.to_h do |primitive|
          [primitive.fetch('datatype').fetch('dsl').delete_prefix('#'), primitive.fetch('enum')]
        end
        deep_freeze(metamodel)
      end

      def deep_freeze(value)
        case value
        when Hash then value.each_value { deep_freeze(_1) }
        when Array then value.each { deep_freeze(_1) }
        end
        value.freeze
      end
    end
  end
end
