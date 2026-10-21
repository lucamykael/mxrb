# frozen_string_literal: true

module Mxrb
  module Compiler
    # Compiles the legacy grids of the web documents the way MxBuild lists them
    # in the navigation document: every data grid, template grid and reference
    # set selector, in the order of the MPR units and of the widget tree, with
    # the entity, attribute paths and column kinds the Runtime resolves.
    class NavigationGridCompiler
      include RuntimeNodes

      GRID_TYPES = %w[Forms$DataGrid Forms$TemplateGrid Forms$ReferenceSetSelector].freeze
      # The column kind of each attribute type, as the Runtime names them.
      COLUMN_KINDS = {
        'String' => 'String', 'HashedString' => 'String', 'Integer' => 'Integer', 'Long' => 'Integer',
        'AutoNumber' => 'Integer', 'Boolean' => 'Boolean', 'DateTime' => 'DateTime',
        'Enumeration' => 'Enumeration', 'Enum' => 'Enumeration', 'Decimal' => 'Decimal'
      }.freeze
      # What MxBuild writes for the settings of a control bar button the MPR leaves out.
      BUTTON_DEFAULTS = {
        'Forms$GridSelectAllButton' => { 'SelectionType' => 'SelectPage' },
        'Forms$DataGridExportToExcelButton' => { 'MaxNumberOfRows' => 1000, 'UseExcelDateType' => true },
        'Forms$DataGridExportToCSVButton' => {
          'MaxNumberOfRows' => 1000, 'DecimalSeparator' => '.', 'GroupSeparator' => ',', 'Delimiter' => ';',
          'GenerateExcelHint' => false, 'UseGridDateFormat' => false
        }
      }.freeze

      def initialize(schema, source, widgets)
        @schema = schema
        @source = source
        @widgets = widgets
        @attributes = AttributeTypeIndex.new(source)
        @page_locations = page_locations(source)
      end

      def compile
        @widgets.documents.flat_map { grids(_1) }.map { node(_1) }
      end

      private

      def grids(value, found = [])
        case value
        when Hash
          found << value if GRID_TYPES.include?(value['$Type'])
          value.each_value { grids(_1, found) }
        when Array then array(value).each { grids(_1, found) }
        end
        found
      end

      def overrides(source)
        case source['$Type']
        when *GRID_TYPES then { 'Entity' => entity(source['DataSource'] || {}) }
        when 'Forms$GridControlBar' then { 'DefaultButtonPointer' => source['DefaultButtonPointer'] || ZERO_UUID }
        when 'Forms$DataGridColumn' then column(source)
        when 'Forms$MicroflowSettings' then { 'ExpectListArgument' => list_microflow?(source['Microflow']) }
        else button_defaults(source)
        end
      end

      def button_defaults(source)
        BUTTON_DEFAULTS.fetch(source['$Type'], {}).reject { |field, _| source.key?(field) }
      end

      # The entity a grid lists: the one its data source names, reaches through
      # an association path or receives from its microflow.
      def entity(data_source)
        reference = data_source['EntityRef'] || {}
        entity = case reference['$Type']
                 when 'DomainModels$DirectEntityRef' then reference['Entity']
                 when 'DomainModels$IndirectEntityRef' then destination(reference)
                 else microflow_entities[data_source.dig('MicroflowSettings', 'Microflow').to_s]
                 end
        (entity || data_source['EntityPath'].to_s.split('/').last).to_s
      end

      def destination(reference) = array(reference['Steps']).last&.fetch('DestinationEntity', nil)

      # A column shows an attribute of the grid's entity or, through the steps
      # of an association path, of an entity it reaches.
      def column(source)
        reference = source['AttributeRef'] || {}
        attribute = reference['Attribute'].to_s
        steps = array((reference['EntityRef'] || {})['Steps']).flat_map { [_1['Association'], _1['DestinationEntity']] }
        { 'AttributePath' => [*steps, attribute].join('/'),
          'ColumnKindString' => COLUMN_KINDS.fetch(@attributes.type(attribute), 'String') }
      end

      def microflows
        @microflows ||= @source.units_of('Microflows$Microflow').to_h do |unit|
          ["#{unit.module_name}.#{unit.document['Name']}", unit.document]
        end
      end

      # The entity each microflow returns a list or an object of.
      def microflow_entities
        @microflow_entities ||= microflows.transform_values { _1.dig('MicroflowReturnType', 'Entity') }
      end

      # Whether a grid button passes its selection to the microflow as a list.
      def list_microflow?(name)
        objects = array(microflows.dig(name.to_s, 'ObjectCollection', 'Objects'))
        objects.any? do |object|
          object['$Type'] == 'Microflows$MicroflowParameter' &&
            object.dig('VariableType', '$Type') == 'DataTypes$ListType'
        end
      end
    end
  end
end
