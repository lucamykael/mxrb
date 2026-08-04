# frozen_string_literal: true

module Mxrb
  module Compiler
    # Read-only indexed view of MPR units used by native materializers.
    class SourceModel
      Unit = Data.define(:id, :container_id, :containment, :document, :module_name)
      CLIENT_TYPE = /\A(?:Forms|JavaScriptActions|Menus|Navigation)\$|\AMicroflows\$Nanoflow\z/

      attr_reader :path, :version, :units

      def self.read(path) = new(File.expand_path(path))

      def initialize(path)
        @path = path
        read_units
      end

      def documents(type = nil)
        selected = type ? units.select { _1.document['$Type'] == type } : units
        selected.map(&:document)
      end

      def units_of(type)
        @units_by_type ||= units.group_by { _1.document['$Type'] }.transform_values(&:freeze).freeze
        @units_by_type.fetch(type, EMPTY_UNITS)
      end

      def document_index
        @document_index ||= {}.tap do |index|
          units.each { index_document(_1.document, index) }
        end.freeze
      end

      def web_page?(unit)
        return false if unit.document['Excluded'] == true

        layout_name = unit.document.dig('FormCall', 'Form').to_s
        layout = units_of('Forms$Layout').find do |candidate|
          "#{candidate.module_name}.#{candidate.document['Name']}" == layout_name
        end
        layout.nil? || layout.document.dig('Content', '$Type') != 'Forms$NativeLayoutContent'
      end

      def web_layout?(unit)
        unit.document['Excluded'] != true &&
          unit.document.dig('Content', '$Type') == 'Forms$WebLayoutContent'
      end

      def optimized_web_client?
        settings = documents('Settings$ProjectSettings').first
        web = nested_values(settings).find { _1.is_a?(Hash) && _1['$Type'] == 'Forms$WebUIProjectSettingsPart' }
        web&.fetch('UseOptimizedClient', nil).to_s == 'Yes'
      end

      def client_reference?(qualified_name)
        reference = /(?:\A|[^A-Za-z0-9_.])@#{Regexp.escape(qualified_name)}(?![A-Za-z0-9_.])/
        units.any? do |unit|
          unit.document['$Type'].to_s.match?(CLIENT_TYPE) && deep_string_match?(unit.document, reference)
        end
      end

      private

      EMPTY_UNITS = [].freeze

      def read_units
        mpr = IO::MprFile.open(path, readonly: true)
        @version = mpr.mendix_version
        raw_units = mpr.all_units
        documents = raw_units.to_h { [_1['UnitID'], mpr.parse_contents(_1)] }
        @units = build_units(raw_units, documents)
      ensure
        mpr&.close
      end

      def build_units(raw_units, documents)
        raw_index = raw_units.to_h { [_1['UnitID'], _1] }
        module_names = {}
        raw_units.map do |raw|
          Unit.new(
            id: raw['UnitID'], container_id: raw['ContainerID'],
            containment: raw['ContainmentName'], document: documents.fetch(raw['UnitID']),
            module_name: resolve_module(raw, raw_index, documents, module_names)
          )
        end.freeze
      end

      def resolve_module(raw, raw_index, documents, cache)
        id = raw['UnitID']
        return cache[id] if cache.key?(id)

        document = documents.fetch(id)
        return cache[id] = document['Name'].to_s if document['$Type'] == 'Projects$ModuleImpl'
        return cache[id] = nil if raw['ContainerID'] == id

        parent = raw_index[raw['ContainerID']]
        cache[id] = parent && resolve_module(parent, raw_index, documents, cache)
      end

      def deep_string_match?(value, pattern)
        case value
        when Hash then value.any? { |_key, child| deep_string_match?(child, pattern) }
        when Array then value.any? { deep_string_match?(_1, pattern) }
        else value.is_a?(String) && value.match?(pattern)
        end
      end

      def nested_values(value)
        case value
        when Hash then [value, *value.values.flat_map { nested_values(_1) }]
        when Array then value.flat_map { nested_values(_1) }
        else []
        end
      end

      def index_document(value, index)
        case value
        when Hash
          id = IO::BsonCodec.extract_id(value['$ID'])
          index[id] = value if id
          value.each_value { index_document(_1, index) }
        when Array then value.each { index_document(_1, index) }
        end
      end
    end
  end
end
