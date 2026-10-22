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
        @attribute_types = attribute_type_index(source)
        @page_locations = page_locations(source)
        @captions = ActivityCaption.new(source)
        @flow_returns = flow_return_index(source)
        @void_java_actions = void_java_actions(source)
        @void_microflows = void_microflows(source)
        @code_action_returns = code_action_returns(source)
        @variable_types = {}
      end

      # The entity of each object variable of a flow, "[entity]" for a list.
      def prepare(flow)
        @variable_types = IMPLICIT_VARIABLES.dup
        nodes = []
        visit(flow) { nodes << _1 }
        # A variable may come from one typed by a later node; settle the chain.
        6.times do
          before = @variable_types.dup
          nodes.each { infer_variable(_1) }
          break if before == @variable_types
        end
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
        if field == 'ValueExpression' && source['$Type'] == 'Microflows$EntityTypeCodeActionParameterValue'
          return "'#{source.fetch('Entity')}'"
        end

        return '' if field == 'ResultVariableName' && unused_result?(source)

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

      # MxBuild keeps no result variable for a call whose return value the flow
      # does not use, nor for a Java action or microflow that returns nothing.
      def unused_result?(source)
        case source['$Type']
        when 'Microflows$JavaActionCallAction'
          source['UseReturnVariable'] == false || @void_java_actions.include?(source['JavaAction'].to_s)
        when 'Microflows$MicroflowCallAction'
          source['UseReturnVariable'] == false || void_microflow?(source.dig('MicroflowCall', 'Microflow'))
        else false
        end
      end

      def void_microflow?(name) = @void_microflows.include?(name.to_s)

      def converted_field(source, source_field, runtime_field)
        value = source[source_field]
        # A REST call without a timeout, or with its timeout off, waits 0, as MxBuild writes it.
        if runtime_field == 'RequestTimeOutExpression' && (value.to_s.empty? || source['UseRequestTimeOut'] == false)
          return '0'
        end
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
          return 'Decimal' if source['AggregateFunction'] == 'Average'

          type = @attribute_types[source['Attribute'].to_s]
          return type if type

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
        from_parent = start == association[:parent] || specializes?(start, association[:parent])
        from_child = !from_parent && (start == association[:child] || specializes?(start, association[:child]))
        # A retrieve from a variable of another type, or from a list, has no type MxBuild can name.
        return 'Unknown' if start && !from_parent && !from_child

        target = from_child ? association[:parent] : association[:child]
        return if target.to_s.empty?

        list = association[:reference_set] || (from_child && !association[:one_to_one])
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
          reference_set: association['Type'] == 'ReferenceSet', one_to_one: one_to_one?(association)
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

      # The objects every flow can read, $latestHttpResponse after a REST call.
      IMPLICIT_VARIABLES = {
        'currentUser' => 'System.User', 'currentSession' => 'System.Session', 'latestError' => 'System.Error',
        'latestHttpResponse' => 'System.HttpResponse', 'latestSoapFault' => 'System.SoapFault'
      }.freeze
      LIST_ELEMENT_OPERATIONS = %w[Head Find FindByExpression FindByAttribute FindByAssociation].freeze
      LIST_OPERATIONS = %w[Tail Filter FilterByExpression FilterByAttribute FilterByAssociation Sort Union Intersect
                           Subtract].freeze
      private_constant :IMPLICIT_VARIABLES, :LIST_ELEMENT_OPERATIONS, :LIST_OPERATIONS

      def infer_variable(node) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength
        name, type = case node['$Type']
                     when 'Microflows$MicroflowParameter' then [node['Name'], object_type(node['VariableType'])]
                     when 'Microflows$CreateChangeAction' then [node['VariableName'], node['Entity']]
                     when 'Microflows$CreateListAction' then [node['VariableName'], "[#{node['Entity']}]"]
                     when 'Microflows$RetrieveAction' then [node['ResultVariableName'], retrieved_type(node)]
                     when 'Microflows$MicroflowCallAction'
                       [node['ResultVariableName'], @flow_returns[node.dig('MicroflowCall', 'Microflow').to_s]]
                     when 'Microflows$NanoflowCallAction'
                       [node['OutputVariableName'], @flow_returns[node.dig('NanoflowCall', 'Nanoflow').to_s]]
                     when 'Microflows$JavaActionCallAction'
                       [node['ResultVariableName'], code_action_result(node['JavaAction'], node['ParameterMappings'])]
                     when 'Microflows$JavaScriptActionCallAction'
                       [node['ResultVariableName'], @code_action_returns[node['JavaScriptAction'].to_s]]
                     when 'Microflows$ResultHandling'
                       [node['ResultVariableName'] || node['VariableName'], object_type(node['VariableType'])]
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

      def void_microflows(source)
        return [] unless source.respond_to?(:units_of)

        source.units_of('Microflows$Microflow').filter_map do |unit|
          void = unit.document.dig('MicroflowReturnType', '$Type') == 'DataTypes$VoidType'
          "#{unit.module_name}.#{unit.document['Name']}" if void
        end
      end

      def void_java_actions(source)
        return [] unless source.respond_to?(:units_of)

        source.units_of('JavaActions$JavaAction').filter_map do |unit|
          void = unit.document.dig('JavaReturnType', '$Type') == 'CodeActions$VoidType'
          "#{unit.module_name}.#{unit.document['Name']}" if void
        end
      end

      def flow_return_index(source)
        return {} unless source.respond_to?(:units_of)

        %w[Microflows$Microflow Microflows$Nanoflow].flat_map { source.units_of(_1) }.to_h do |unit|
          ["#{unit.module_name}.#{unit.document['Name']}", object_type(unit.document['MicroflowReturnType'])]
        end
      end

      # The entity, or list of an entity, each Java or JavaScript action returns;
      # a type parameter stands for the entity the call names for it.
      def code_action_returns(source)
        return {} unless source.respond_to?(:units_of)

        %w[JavaActions$JavaAction JavaScriptActions$JavaScriptAction].flat_map { source.units_of(_1) }.to_h do |unit|
          type = unit.document['JavaReturnType'] || unit.document['ActionReturnType'] || {}
          ["#{unit.module_name}.#{unit.document['Name']}", code_action_object_type(type, unit)]
        end
      end

      def code_action_object_type(type, unit)
        case type['$Type'].to_s.sub(/\AJavaActions\$/, 'CodeActions$')
        when 'CodeActions$ConcreteEntityType' then type['Entity'].to_s
        when 'CodeActions$ListType' then list_of(code_action_object_type(type['Parameter'] || {}, unit))
        when 'CodeActions$ParameterizedEntityType' then type_parameter_holder(type, unit)
        end
      end

      def list_of(element) = element.is_a?(Hash) ? element.merge(list: true) : "[#{element}]"

      # The qualified name of the parameter that names the entity of a type parameter.
      def type_parameter_holder(type, unit)
        pointer = IO::BsonCodec.extract_id(type['TypeParameterPointer'])
        parameter = array(unit.document['Parameters']).find do |candidate|
          IO::BsonCodec.extract_id(candidate.dig('ParameterType', 'TypeParameterPointer')) == pointer
        end
        { parameter: "#{unit.module_name}.#{unit.document['Name']}.#{parameter['Name']}" } if parameter
      end

      def code_action_result(action, mappings)
        type = @code_action_returns[action.to_s]
        return type unless type.is_a?(Hash)

        mapping = array(mappings).find { _1['Parameter'] == type[:parameter] }
        entity = mapping&.dig('Value', 'Entity').to_s
        return if entity.empty?

        type[:list] ? "[#{entity}]" : entity
      end

      AGGREGATE_TYPES = {
        'DomainModels$IntegerAttributeType' => 'Integer', 'DomainModels$LongAttributeType' => 'Long',
        'DomainModels$AutoNumberAttributeType' => 'Long', 'DomainModels$DecimalAttributeType' => 'Decimal',
        'DomainModels$DateTimeAttributeType' => 'DateTime'
      }.freeze
      private_constant :AGGREGATE_TYPES

      # The type a sum, minimum or maximum of each numeric or date attribute has.
      def attribute_type_index(source)
        return {} unless source.respond_to?(:units_of)

        source.units_of('DomainModels$DomainModel').each_with_object({}) do |unit, result|
          array(unit.document['Entities']).each do |entity|
            array(entity['Attributes']).each do |attribute|
              type = AGGREGATE_TYPES[attribute.dig('NewType', '$Type').to_s]
              result["#{unit.module_name}.#{entity['Name']}.#{attribute['Name']}"] = type if type
            end
          end
        end
      end

      def association_index(source)
        return {} unless source.respond_to?(:units_of)

        source.units_of('DomainModels$DomainModel').each_with_object({}) do |unit, result|
          entities = array(unit.document['Entities']).to_h do |entity|
            [IO::BsonCodec.extract_id(entity['$ID']), "#{unit.module_name}.#{entity['Name']}"]
          end
          associations = array(unit.document['Associations']) + array(unit.document['CrossAssociations'])
          associations.each do |association|
            result["#{unit.module_name}.#{association['Name']}"] = {
              parent: entities[IO::BsonCodec.extract_id(association['ParentPointer'])],
              child: association_child(association, entities),
              reference_set: association['Type'] == 'ReferenceSet', one_to_one: one_to_one?(association)
            }
          end
        end
      end

      # A cross-module association names its child entity.
      def association_child(association, entities)
        return association['Child'].to_s if association.key?('Child')

        entities[IO::BsonCodec.extract_id(association['ChildPointer'])]
      end

      # A reference both entities own links one object to one object.
      def one_to_one?(association) = association['Type'] == 'Reference' && association['Owner'] == 'Both'

      def visit(value, &block)
        case value
        when Hash
          block.call(value) if value['$Type']
          value.each_value { visit(_1, &block) }
        when Array then value.each { visit(_1, &block) }
        end
      end
    end
    # rubocop:enable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity
    # rubocop:enable Metrics/MethodLength, Metrics/PerceivedComplexity
  end
end
