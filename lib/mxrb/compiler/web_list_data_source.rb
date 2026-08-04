# frozen_string_literal: true

module Mxrb
  module Compiler
    # Resolves React list data sources and safely lowers unusable simple connector reads to XPath.
    # rubocop:disable Metrics
    class WebListDataSource
      include ModelValues

      attr_reader :association_path, :entity, :microflow_name, :nanoflow_name, :xpath_constraint

      def initialize(source, widget)
        @source = source
        @widget = widget
        resolve_sources
        resolve_flows
        resolve_entity
        @xpath_constraint = @xpath&.fetch('XPathConstraint', '').to_s
      end

      def resolve_sources
        direct = widget['DataSource'] if widget.is_a?(Hash)
        @xpath = direct if database_source?(direct)
        @xpath ||= nested(widget, 'CustomWidgets$CustomWidgetXPathSource').first
        @association_source = direct if direct&.fetch('$Type', nil) == 'Forms$AssociationSource'
        @association_source ||= nested(widget, 'Forms$AssociationSource').first
        @microflow_source = direct if direct&.fetch('$Type', nil) == 'Forms$MicroflowSource'
        @microflow_source ||= nested(widget, 'Forms$MicroflowSource').first
        @nanoflow_source = direct if direct&.fetch('$Type', nil) == 'Forms$NanoflowSource'
        @nanoflow_source ||= nested(widget, 'Forms$NanoflowSource').first
        @microflow_name = flow_name(@microflow_source, 'Microflow')
        @nanoflow_name = @nanoflow_source&.fetch('Nanoflow', '').to_s
        @association_path = entity_ref_path(@association_source&.fetch('EntityRef', nil))
      end

      def flow_name(source, key)
        source&.dig("#{key}Settings", key).to_s.then do |name|
          name.empty? ? source&.fetch(key, '').to_s : name
        end
      end

      def resolve_flows
        @flow = qualified_unit('Microflows$Microflow', microflow_name) unless microflow_name.empty?
        @nanoflow = qualified_unit('Microflows$Nanoflow', nanoflow_name) unless nanoflow_name.empty?
      end

      def resolve_entity
        @entity = [
          entity_ref_destination(@xpath&.fetch('EntityRef', nil)),
          entity_ref_destination(@association_source&.fetch('EntityRef', nil)),
          @flow&.document&.dig('MicroflowReturnType', 'Entity'),
          @nanoflow&.document&.dig('MicroflowReturnType', 'Entity')
        ].map(&:to_s).find { !_1.empty? }.to_s
      end

      def supported? = xpath? || association? || microflow? || nanoflow?
      def xpath? = !@xpath.nil? || connector_fallback?
      def association? = !@association_source.nil? && !association_path.empty? && !entity.empty?
      def microflow? = !@microflow_source.nil? && !microflow_name.empty? && !@flow.nil?
      def nanoflow? = !@nanoflow_source.nil? && !nanoflow_name.empty? && !@nanoflow.nil?

      private

      attr_reader :widget

      def database_source?(source)
        %w[Forms$DatabaseSource Forms$NewListViewDatabaseSource Forms$ListViewXPathSource]
          .include?(source&.fetch('$Type', nil))
      end

      def entity_ref_destination(reference)
        steps = array(reference&.fetch('Steps', nil))
        steps.last&.fetch('DestinationEntity', nil) || reference&.fetch('Entity', nil)
      end

      def entity_ref_path(reference)
        array(reference&.fetch('Steps', nil)).flat_map do |step|
          [step['Association'], step['DestinationEntity']]
        end.map(&:to_s).reject(&:empty?).join('/')
      end

      def connector_fallback?
        return @connector_fallback unless @connector_fallback.nil?

        @connector_fallback = connector_action.then do |action|
          action && simple_unconfigured_query?(action)
        end
      end

      def connector_action
        actions = nested(@flow&.document, 'DatabaseConnector$ExecuteDatabaseQueryAction')
        actions.one? ? actions.first : nil
      end

      def simple_unconfigured_query?(action)
        connection, query = connector_query(action['Query'].to_s)
        return false unless connection && query && connection_unconfigured?(connection)
        return false unless query['Query'].to_s.match?(/\A\s*select\s+.+\s+from\s+[A-Za-z_][A-Za-z0-9_]*\s*;?\s*\z/im)

        mappings = array(query['TableMappings'])
        mappings.one? && mappings.first['Entity'].to_s == entity
      end

      def connector_query(qualified)
        connection_name, _, query_name = qualified.rpartition('.')
        unit = @source.units.find do |candidate|
          candidate.document['$Type'] == 'DatabaseConnector$DatabaseConnection' &&
            "#{candidate.module_name}.#{candidate.document['Name']}" == connection_name
        end
        [unit&.document, array(unit&.document&.fetch('Queries', nil)).find { _1['Name'] == query_name }]
      end

      def connection_unconfigured?(connection)
        %w[ConnectionString UserName Password].all? do |field|
          name = connection[field].to_s
          constant = qualified_unit('Constants$Constant', name) unless name.empty?
          constant && constant.document.fetch('DefaultValue', nil).to_s.empty?
        end
      end

      def qualified_unit(type, qualified)
        @source.units_of(type).find do |unit|
          "#{unit.module_name}.#{unit.document['Name']}" == qualified
        end
      end

      def nested(value, type, result = [])
        case value
        when Hash
          result << value if value['$Type'] == type
          value.each_value { nested(_1, type, result) }
        when Array then value.each { nested(_1, type, result) }
        end
        result
      end
    end
    # rubocop:enable Metrics
  end
end
