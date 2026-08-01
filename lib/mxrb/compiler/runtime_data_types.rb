# frozen_string_literal: true

module Mxrb
  module Compiler
    # Maps editable MPR data-type documents to Runtime type identifiers.
    module RuntimeDataTypes
      SCALARS = {
        'DataTypes$VoidType' => 'Void', 'DataTypes$StringType' => 'String',
        'DataTypes$BooleanType' => 'Boolean', 'DataTypes$IntegerType' => 'Integer',
        'DataTypes$DecimalType' => 'Decimal', 'DataTypes$DateTimeType' => 'DateTime'
      }.freeze

      private

      def data_type(document) # rubocop:disable Metrics/AbcSize
        return 'Void' unless document
        return SCALARS.fetch(document['$Type']) if SCALARS.key?(document['$Type'])
        return document['Entity'].to_s if document['$Type'] == 'DataTypes$ObjectType'
        return "[#{document['Entity']}]" if document['$Type'] == 'DataTypes$ListType'
        return "##{document['Enumeration']}" if document['$Type'] == 'DataTypes$EnumerationType'
        return 'Unknown' if document['$Type'] == 'DataTypes$UnknownType'

        raise CompilationError, "unsupported Runtime data type #{document['$Type']}"
      end # rubocop:enable Metrics/AbcSize

      def data_type_document?(value)
        value.is_a?(Hash) && value['$Type'].to_s.start_with?('DataTypes$')
      end
    end
  end
end
