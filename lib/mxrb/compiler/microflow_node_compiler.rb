# frozen_string_literal: true

require 'digest'

module Mxrb
  module Compiler
    # rubocop:disable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity
    # rubocop:disable Metrics/MethodLength, Metrics/PerceivedComplexity
    # Recursively compiles ordered objects nested inside microflow graphs.
    class MicroflowNodeCompiler
      include ModelValues
      include RuntimeDataTypes

      FIELD_SOURCES = {
        ['Microflows$BasicCodeActionParameterValue', 'ValueExpression'] => 'Argument',
        ['Microflows$CreateVariableAction', 'Type'] => 'VariableType',
        ['Microflows$MicroflowParameter', 'Type'] => 'VariableType',
        ['Microflows$MappingRequestHandling', 'ContentTypeRuntime'] => 'ContentType',
        ['Microflows$RetrieveSorting', 'AttributePath'] => 'AttributeRef',
        ['Microflows$RestCallAction', 'RequestTimeOutExpression'] => 'TimeOutExpression',
        ['Microflows$ResultHandling', 'VariableDataType'] => 'VariableType'
      }.freeze
      TYPE_DEFAULTS = {
        'Microflows$NoCase' => { 'StringRepresentation' => '' },
        # A change item stores only the member it sets; MxBuild writes the other one empty.
        'Microflows$ChangeActionItem' => { 'Attribute' => '', 'Association' => '' },
        'Microflows$DeleteAction' => { 'ErrorHandlingType' => 'Rollback' },
        'Microflows$AggregateAction' => {
          'Expression' => '', 'UseExpression' => false,
          'ReduceInitialValueExpression' => ''
        }
      }.freeze
      RUNTIME_DERIVED_FIELDS = {
        'Microflows$ActionActivity' => %w[Caption]
      }.freeze
      EDITORIAL_TYPES = %w[Microflows$AnnotationFlow].freeze

      def initialize(schema, source: nil)
        @schema = schema
        @database_connector = DatabaseConnectorActionCompiler.new(source) if source.respond_to?(:units)
        @associations = association_index(source)
        @page_locations = page_location_index(source)
        @captions = ActivityCaption.new(source)
        @flow_returns = flow_return_index(source)
        @variable_types = {}
      end

      # The entity of each object variable of a flow, "[entity]" for a list.
      def prepare(flow)
        @variable_types = {}
        nodes = []
        visit(flow) { nodes << _1 }
        2.times { nodes.each { infer_variable(_1) } }
      end

      def compile(value)
        case value
        when Hash then compile_hash(value)
        when Array then array(value).filter_map { compile(_1) }
        else value
        end
      end

      private

      def compile_hash(value)
        return value.to_h { |key, child| [key, compile(child)] } unless value['$Type']
        return nil if EDITORIAL_TYPES.include?(value['$Type'])
        return compile_custom_range(value) if value['$Type'] == 'Microflows$CustomRange'

        if value['$Type'] == 'DatabaseConnector$ExecuteDatabaseQueryAction'
          return compile(noop_database_action(value)) if @database_connector.unconfigured_write?(value)

          return compile(@database_connector.compile(value))
        end

        compile_node(value)
      end

      def compile_custom_range(source)
        {
          '$ID' => derived_id(source, 'constant-range'), '$Type' => 'Microflows$ConstantRange',
          'SingleObject' => source['SingleObject'] == true
        }
      end

      def noop_database_action(source)
        {
          '$ID' => source['$ID'], '$Type' => 'Microflows$LogMessageAction',
          'MessageTemplate' => {
            '$ID' => derived_id(source, 'local-fallback-message'),
            '$Type' => 'Microflows$StringTemplate', 'Parameters' => [], 'Text' => ''
          },
          'ErrorHandlingType' => source.fetch('ErrorHandlingType', 'Rollback'),
          'Level' => 'Trace', 'Node' => "'Mxrb'", 'IncludeLatestStackTrace' => false
        }
      end

      def compile_node(source)
        @schema.fields_for(source).to_h { |field| [field, node_value(source, field)] }
      end

      def node_value(source, field)
        return source[field] if %w[$ID $Type].include?(field)
        if field == 'Type' && %w[
          Microflows$AssociationRetrieveSource Microflows$DatabaseRetrieveSource
        ].include?(source['$Type'])
          return retrieve_type(source)
        end
        if field == 'StringRepresentation' && source['$Type'] == 'Microflows$InheritanceCase'
          return derived_default(source, field)
        end
        if field == 'ValueExpression' && source['$Type'] == 'Microflows$MicroflowParameterValue'
          return "'#{source.fetch('Microflow')}'"
        end

        if field == 'Caption' && source['$Type'] == 'Microflows$ActionActivity' && source['AutoGenerateCaption'] == true
          generated = generated_caption(source['Action'] || {})
          return generated if generated
        end

        existing = @schema.counterpart(source)
        if RUNTIME_DERIVED_FIELDS.fetch(source['$Type'], []).include?(field) && existing&.key?(field)
          return existing[field]
        end

        source_field = if source.key?(field)
                         field
                       else
                         FIELD_SOURCES.fetch([source['$Type'], field], field)
                       end
        return converted_field(source, source_field, field) if source.key?(source_field)

        default_or_existing(source, field)
      end

      def converted_field(source, source_field, runtime_field)
        value = source[source_field]
        return runtime_attribute_path(value) if runtime_field == 'AttributePath'
        return data_type(value) if %w[Type VariableDataType].include?(runtime_field) && data_type_document?(value)

        compile(value)
      end

      def runtime_attribute_path(reference)
        attribute = if reference.is_a?(Hash)
                      reference.fetch('Attribute', '').to_s
                    else
                      reference.to_s
                    end
        entity = attribute.rpartition('.').first
        entity.empty? ? attribute : "#{entity}/#{attribute}"
      end

      def default_or_existing(source, field)
        defaults = TYPE_DEFAULTS.fetch(source['$Type'], {})
        return defaults[field] if defaults.key?(field)

        existing = @schema.counterpart(source)
        return existing[field] if existing&.key?(field)

        derived_default(source, field)
      end

      def derived_default(source, field)
        case field
        when 'Argument' then source.dig('Value', 'Argument').to_s
        when 'QueueSettings', 'NewCaseValue' then nil
        when 'Location' then @page_locations.fetch(source['Form'].to_s, 'Content')
        when 'ParameterMappings' then []
        when 'StringRepresentation'
          return '(empty)' if source['$Type'] == 'Microflows$InheritanceCase' && source['Value'].to_s.empty?

          source['Value'].to_s
        when 'Type' then derived_runtime_type(source)
        when 'IsRequired', 'Disabled' then source.fetch(field, false) == true
        when 'DefaultValue', 'Caption', 'ResultVariableName', 'OutputVariableName',
             'FormObjectVariable', 'Queue' then ''
        else raise CompilationError, "cannot derive Runtime field #{source['$Type']}.#{field}"
        end
      end

      def derived_runtime_type(source)
        if source['$Type'] == 'Microflows$AggregateAction'
          return 'Integer' if source['AggregateFunction'] == 'Count'

          raise CompilationError,
                "cannot derive #{source['AggregateFunction']} aggregate type without an audited attribute type"
        end

        retrieve_type(source)
      end

      def retrieve_type(source)
        return association_retrieve_type(source) if source['$Type'] == 'Microflows$AssociationRetrieveSource'
        unless source['$Type'] == 'Microflows$DatabaseRetrieveSource'
          raise CompilationError, "cannot derive Runtime retrieve type for #{source['$Type']}"
        end

        single = source.dig('Range', 'SingleObject') == true
        single ? source['Entity'].to_s : "[#{source['Entity']}]"
      end

      def association_retrieve_type(source)
        association = @associations[source['AssociationId'].to_s] || runtime_association(source['AssociationId'].to_s)
        raise CompilationError, "unknown association #{source['AssociationId'].inspect}" unless association

        start = @variable_types[source['StartVariableName'].to_s]
        from_child = start == association[:child] ||
                     (!specializes?(start, association[:parent]) && specializes?(start, association[:child]))
        target = from_child ? association[:parent] : association[:child]
        return if target.to_s.empty?

        list = association[:reference_set] || from_child
        list ? "[#{target}]" : target
      end

      # Whether an entity is another one or one of its specializations.
      def specializes?(entity, ancestor)
        seen = []
        while entity && !seen.include?(entity)
          return true if entity == ancestor

          seen << entity
          entity = @schema.respond_to?(:named) && @schema.named(entity)&.dig('MaybeGeneralization', 'Generalization')
        end
        false
      end

      def runtime_association(name)
        association = @schema.respond_to?(:named) && @schema.named(name)
        return unless association

        parent = @schema.counterpart_id(association['ParentPointer'])
        child = @schema.counterpart_id(association['ChildPointer'])
        {
          parent: parent&.fetch('QualifiedName', nil), child: child&.fetch('QualifiedName', nil),
          reference_set: association['Type'] == 'ReferenceSet'
        }
      end

      def generated_caption(action)
        retrieve = action['RetrieveSource']
        type = association_retrieve_type(retrieve) if retrieve&.fetch('$Type',
                                                                      nil) == 'Microflows$AssociationRetrieveSource'
        @captions.caption(action, variables: @variable_types, retrieve_type: type)
      rescue CompilationError
        nil
      end

      LIST_ELEMENT_OPERATIONS = %w[Head Find FindByExpression FindByAttribute FindByAssociation].freeze
      LIST_OPERATIONS = %w[Tail Filter FilterByExpression FilterByAttribute FilterByAssociation Sort Union Intersect
                           Subtract].freeze
      private_constant :LIST_ELEMENT_OPERATIONS, :LIST_OPERATIONS

      def infer_variable(node) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength
        name, type = case node['$Type']
                     when 'Microflows$MicroflowParameter' then [node['Name'], object_type(node['VariableType'])]
                     when 'Microflows$CreateChangeAction' then [node['VariableName'], node['Entity']]
                     when 'Microflows$CreateListAction' then [node['VariableName'], "[#{node['Entity']}]"]
                     when 'Microflows$RetrieveAction' then [node['ResultVariableName'], retrieved_type(node)]
                     when 'Microflows$MicroflowCallAction'
                       [node['ResultVariableName'], @flow_returns[node.dig('MicroflowCall', 'Microflow').to_s]]
                     when 'Microflows$LoopedActivity' then loop_variable(node)
                     when 'Microflows$ListOperationsAction' then list_operation_variable(node)
                     end
        @variable_types[name.to_s] = type.to_s unless name.to_s.empty? || type.to_s.empty? || type.to_s == '[]'
      end

      def object_type(type)
        entity = type&.fetch('Entity', nil).to_s
        return if entity.empty?

        type['$Type'] == 'DataTypes$ListType' ? "[#{entity}]" : entity
      end

      def retrieved_type(action)
        source = action['RetrieveSource'] || {}
        if source['$Type'] == 'Microflows$DatabaseRetrieveSource'
          range = source['Range'] || {}
          single = range['$Type'] == 'Microflows$ConstantRange' && range['SingleObject'] == true
          single ? source['Entity'] : "[#{source['Entity']}]"
        elsif @variable_types.key?(source['StartVariableName'].to_s)
          association_retrieve_type(source)
        end
      rescue CompilationError
        nil
      end

      def loop_variable(node)
        source = node['LoopSource'] || {}
        list = source['ListVariableName'] || node['IteratedListVariableName']
        element = @variable_types[list.to_s].to_s.delete_prefix('[').delete_suffix(']')
        [source['VariableName'] || node['LoopVariableName'], element]
      end

      def list_operation_variable(node)
        operation = node['NewOperation'] || {}
        kind = operation['$Type'].to_s.delete_prefix('Microflows$')
        list = @variable_types[operation['ListName'].to_s].to_s
        type = if LIST_ELEMENT_OPERATIONS.include?(kind) then list.delete_prefix('[').delete_suffix(']')
               elsif LIST_OPERATIONS.include?(kind) then list
               end
        [node['ResultVariableName'], type]
      end

      def flow_return_index(source)
        return {} unless source.respond_to?(:units_of)

        source.units_of('Microflows$Microflow').to_h do |unit|
          ["#{unit.module_name}.#{unit.document['Name']}", object_type(unit.document['MicroflowReturnType'])]
        end
      end

      # Where a page opens by default: in a popup when its layout is one, as MxBuild
      # writes the location of a show page action that does not choose one.
      def page_location_index(source)
        return {} unless source.respond_to?(:units_of)

        layouts = source.units_of('Forms$Layout').to_h do |unit|
          ["#{unit.module_name}.#{unit.document['Name']}", unit.document.dig('Content', 'LayoutType').to_s]
        end
        source.units_of('Forms$Page').each_with_object({}) do |unit, result|
          type = layouts[unit.document.dig('FormCall', 'Form').to_s]
          result["#{unit.module_name}.#{unit.document['Name']}"] = type if %w[Popup ModalPopup].include?(type)
        end
      end

      def association_index(source)
        return {} unless source.respond_to?(:units_of)

        source.units_of('DomainModels$DomainModel').each_with_object({}) do |unit, result|
          entities = array(unit.document['Entities']).to_h do |entity|
            [IO::BsonCodec.extract_id(entity['$ID']), "#{unit.module_name}.#{entity['Name']}"]
          end
          array(unit.document['Associations']).each do |association|
            result["#{unit.module_name}.#{association['Name']}"] = {
              parent: entities[IO::BsonCodec.extract_id(association['ParentPointer'])],
              child: entities[IO::BsonCodec.extract_id(association['ChildPointer'])],
              reference_set: association['Type'] == 'ReferenceSet'
            }
          end
        end
      end

      def visit(value, &block)
        case value
        when Hash
          block.call(value) if value['$Type']
          value.each_value { visit(_1, &block) }
        when Array then value.each { visit(_1, &block) }
        end
      end

      def derived_id(source, label)
        seed = "#{IO::BsonCodec.extract_id(source['$ID'])}:#{label}"
        hex = Digest::SHA256.hexdigest(seed)[0, 32]
        "#{hex[0, 8]}-#{hex[8, 4]}-4#{hex[13, 3]}-8#{hex[17, 3]}-#{hex[20, 12]}"
      end
    end
    # rubocop:enable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity
    # rubocop:enable Metrics/MethodLength, Metrics/PerceivedComplexity
  end
end
