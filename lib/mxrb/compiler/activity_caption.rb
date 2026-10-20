# frozen_string_literal: true

module Mxrb
  module Compiler
    # The caption Studio Pro generates for an action activity whose caption is
    # automatic, as MxBuild writes it into model.mdp. An action it has no rule
    # for gives nil, and the activity keeps the caption the MPR stores.
    class ActivityCaption # rubocop:disable Metrics/ClassLength
      VARIABLE_TYPES = {
        'DataTypes$BooleanType' => 'Boolean', 'DataTypes$StringType' => 'String',
        'DataTypes$IntegerType' => 'Integer/Long', 'DataTypes$LongType' => 'Integer/Long',
        'DataTypes$DecimalType' => 'Decimal', 'DataTypes$DateTimeType' => 'Date and time'
      }.freeze
      CODE_ACTIONS = %w[JavaActions$JavaAction JavaScriptActions$JavaScriptAction].freeze

      def initialize(source)
        @code_actions = code_action_captions(source)
        @language = default_language(source)
      end

      # variables: name => entity, "[entity]" for a list; retrieve_type: the
      # result type of an association retrieve, in the same form.
      def caption(action, variables: {}, retrieve_type: nil) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength
        @variables = variables
        case action['$Type'].to_s.delete_prefix('Microflows$')
        when 'CreateChangeAction' then "Create #{short(action['Entity'])}#{members(action)}"
        when 'ChangeAction' then "Change '#{action['ChangeVariableName']}'#{members(action)}"
        when 'ChangeVariableAction' then "Change variable #{action['ChangeVariableName']}"
        when 'CreateVariableAction' then create_variable(action)
        when 'CommitAction' then "Commit '#{action['CommitVariableName']}'"
        when 'DeleteAction' then delete(action['DeleteVariableName'].to_s)
        when 'RetrieveAction' then retrieve(action, retrieve_type)
        when 'CreateListAction' then "Create list of #{short(action['Entity'])}"
        when 'ChangeListAction' then change_list(action)
        when 'ShowFormAction' then "Show page '#{short(action.dig('FormSettings', 'Form'))}'"
        when 'CloseFormAction' then 'Close page'
        when 'ShowMessageAction' then message(action.dig('Template', 'Text'))
        when 'ValidationFeedbackAction' then validation(action)
        when 'LogMessageAction' then "Log message (#{action['Level'].to_s.downcase})"
        when 'MicroflowCallAction' then short(action.dig('MicroflowCall', 'Microflow'))
        when 'NanoflowCallAction' then short(action.dig('NanoflowCall', 'Nanoflow'))
        when 'JavaActionCallAction' then code_action(action['JavaAction'])
        when 'JavaScriptActionCallAction' then code_action(action['JavaScriptAction'])
        when 'CastAction' then 'Cast object'
        when 'RestCallAction' then "Call REST (#{action.dig('HttpConfiguration', 'HttpMethod').to_s.upcase})"
        when 'SynchronizeAction' then ('Synchronize everything' if action['Type'] == 'All')
        when 'PushToClientAction' then "Synchronize '#{action['DataVariableName']}' to device"
        when 'ListOperationsAction' then list_operation(action)
        when 'AggregateAction' then aggregate(action)
        end
      end

      private

      def members(action)
        names = items(action['Items']).map { short(_1['Attribute'].to_s.empty? ? _1['Association'] : _1['Attribute']) }
        names.empty? ? '' : " (#{names.join(', ')})"
      end

      def create_variable(action)
        type = VARIABLE_TYPES[action.dig('VariableType', '$Type').to_s]
        "Create #{type} variable" if type
      end

      def delete(variable)
        type = @variables[variable]
        return unless type

        type.start_with?('[') ? "Delete objects in '#{variable}'" : "Delete '#{variable}'"
      end

      def retrieve(action, type)
        source = action['RetrieveSource'] || {}
        case source['$Type']
        when 'Microflows$DatabaseRetrieveSource' then database_retrieve(source)
        when 'Microflows$AssociationRetrieveSource' then association_retrieve(source, type.to_s)
        end
      end

      def database_retrieve(source)
        range = source['Range'] || {}
        single = range['$Type'] == 'Microflows$ConstantRange' && range['SingleObject'] == true
        "Retrieve #{'list of ' unless single}#{short(source['Entity'])} from database"
      end

      def association_retrieve(source, type)
        return if type.empty?

        "Retrieve #{'list of ' if type.start_with?('[')}#{short(type.delete_prefix('[').delete_suffix(']'))} " \
          "by $#{source['StartVariableName']}/#{short(source['AssociationId'])}"
      end

      def change_list(action)
        case action['Type']
        when 'Add' then "Add to list #{action['ChangeVariableName']}"
        when 'Clear' then "Clear list #{action['ChangeVariableName']}"
        end
      end

      def message(text)
        translations = items(text&.fetch('Items', nil))
        chosen = translations.find { _1['LanguageCode'] == @language } || translations.first
        chosen && chosen['Text'].to_s
      end

      def validation(action)
        member = action['Attribute'].to_s.empty? ? action['Association'] : action['Attribute']
        "Show validation message on member #{short(member)} of #{action['ValidationVariableName']}"
      end

      def code_action(name) = @code_actions.fetch(name.to_s) { short(name) }

      def list_operation(action)
        action.dig('NewOperation', '$Type').to_s.delete_prefix('Microflows$').then { _1 == 'Head' ? 'Head' : nil }
      end

      def aggregate(action)
        "Count #{action['AggregateVariableName']}" if action['AggregateFunction'] == 'Count'
      end

      def code_action_captions(source)
        return {} unless source.respond_to?(:units_of)

        CODE_ACTIONS.flat_map { source.units_of(_1) }.to_h do |unit|
          caption = unit.document.dig('MicroflowActionInfo', 'Caption').to_s
          ["#{unit.module_name}.#{unit.document['Name']}", caption.empty? ? unit.document['Name'].to_s : caption]
        end
      end

      def default_language(source)
        settings = source.respond_to?(:documents) ? source.documents('Settings$ProjectSettings').first : nil
        language = items(settings&.fetch('Settings', nil)).find { _1['$Type'] == 'Settings$LanguageSettings' }
        language&.fetch('DefaultLanguageCode', nil).to_s.then { _1.empty? ? 'en_US' : _1 }
      end

      def short(name) = name.to_s.split('.').last.to_s
      def items(value) = IO::BsonCodec.parse_array(value)[:items].grep(Hash)
    end
  end
end
