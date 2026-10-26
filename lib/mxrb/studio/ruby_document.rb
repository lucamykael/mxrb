# frozen_string_literal: true

require 'prism'
require_relative 'files'
require_relative 'ruby_project'
require_relative 'request_context'
require_relative 'ruby_document_aggregates'

module Mxrb
  module Studio
    # Resolves the saved native document's identity to a parsed Ruby declaration.
    # Filenames are not identities: users may move or rename their Ruby files.
    class RubyDocument # rubocop:disable Metrics/ClassLength
      include RubyDocumentAggregates
      DECLARATIONS = {
        'Microflows$Microflow' => 'microflow', 'Microflows$Nanoflow' => 'nanoflow',
        'Microflows$Rule' => 'rule', 'Forms$Page' => 'page', 'Pages$Page' => 'page',
        'Menus$MenuDocument' => 'menu', 'Enumerations$Enumeration' => 'enumeration',
        'Constants$Constant' => 'constant', 'RegularExpressions$RegularExpression' => 'regular_expression',
        'Forms$Layout' => 'layout_document', 'Forms$PageTemplate' => 'page_template_document',
        'Forms$BuildingBlock' => 'building_block_document', 'Forms$Snippet' => 'snippet_document',
        'Images$ImageCollection' => 'image_collection', 'CustomIcons$CustomIconCollection' => 'custom_icon_collection',
        'JavaActions$JavaAction' => 'java_action', 'JavaScriptActions$JavaScriptAction' => 'javascript_action',
        'ScheduledEvents$ScheduledEvent' => 'scheduled_event', 'Workflows$Workflow' => 'workflow',
        'DataSets$DataSet' => 'dataset', 'Queues$Queue' => 'task_queue',
        'ExportMappings$ExportMapping' => 'export_mapping', 'ImportMappings$ImportMapping' => 'import_mapping',
        'JsonStructures$JsonStructure' => 'json_structure', 'XmlSchemas$XmlSchema' => 'xml_schema',
        'Rest$PublishedRestService' => 'published_rest_service',
        'Rest$ConsumedODataService' => 'consumed_odata_service',
        'ODataPublish$PublishedODataService2' => 'published_odata_service',
        'Authentication$Authentication' => 'authentication', 'AppServices$ConsumedAppService' => 'consumed_app_service',
        'WebServices$PublishedService' => 'published_web_service',
        'WebServices$ImportedServiceImpl' => 'imported_web_service',
        'DomainModels$ViewEntitySourceDocument' => 'oql_source_document',
        'DatabaseConnector$DatabaseConnection' => 'database_connection',
        'MessageDefinitions$MessageDefinitionCollection' => 'message_definition_collection'
      }.freeze
      GLOBAL_DECLARATIONS = {
        'Settings$ProjectSettings' => %w[project_settings project_settings_document],
        'Texts$SystemTextCollection' => %w[system_text_collection],
        'Security$ProjectSecurity' => %w[security],
        'Navigation$NavigationDocument' => %w[navigation]
      }.freeze
      # These units have baseline JSON, but the exporter emits no Ruby declaration.
      BASELINE_ONLY_TYPES = %w[
        Projects$Folder Projects$ModuleGuidMapping Projects$ModuleSettings Projects$ProjectConversion
      ].freeze
      MAXIMUM_FILES = 10_000

      def initialize(project, context: RequestContext.new)
        @project = project
        @context = context
      end

      def resolve(unit_id:, qualified_name: nil, type: nil) # rubocop:disable Metrics/MethodLength
        validate_unit_id(unit_id)
        @context.check!
        @document = native_document(unit_id)
        return unavailable('unknown_document', 'The saved native document no longer exists.') unless @document
        unless expected_identity?(qualified_name, type)
          return unavailable('document_changed', 'The saved document identity differs from the open document.')
        end

        representation = @project.status
        return missing_representation unless representation[:state] == 'ready'

        @files = Files.new(representation.fetch(:root))
        @source_paths = source_paths
        aggregate = aggregate_candidates
        return aggregate_result(aggregate) if aggregate

        resolve_candidates
      end

      private

      def missing_representation
        if BASELINE_ONLY_TYPES.include?(@document[:type])
          return unavailable('unsupported_type', 'MXRB preserves this unit as metadata without a Ruby declaration.')
        end

        result(state: 'missing_project')
      end

      def resolve_candidates
        matches = @source_paths.flat_map { candidates(_1) }
        if matches.empty?
          return unavailable('source_not_found', 'No matching Ruby declaration was found in the linked project.')
        end
        return unavailable('ambiguous_source', 'Multiple Ruby declarations match this document.') unless matches.one?

        result(state: 'ready', **matches.first)
      end

      def validate_unit_id(unit_id)
        return if unit_id.is_a?(String) && unit_id.match?(IO::BsonCodec::UUID_PATTERN)

        raise ArgumentError, 'unit_id must be a UUID'
      end

      def expected_identity?(qualified_name, type)
        (!qualified_name || qualified_name == @document[:qualified_name]) && (!type || type == @document[:type])
      end

      def result(state:, **details)
        { state:, source_model: @project.source_model, root: @files&.root, path: nil, line: nil,
          **(@document || {}).except(:module), **details }
      end

      def unavailable(reason, message) = result(state: 'unavailable', reason:, message:)

      def native_document(unit_id) # rubocop:disable Metrics/MethodLength
        mpr = IO::MprFile.open(@project.source_model, readonly: true, apply_studio_compatibility: false)
        begin
          unit = mpr.unit(unit_id)
          return unless unit

          document = mpr.parse_contents(unit)
          @native_contents = document
          mod = module_name(mpr, unit)
          name = document['Name'].to_s
          { unit_id: unit.fetch('UnitID'), type: document['$Type'], name:, module: mod,
            qualified_name: qualified_document_name(document['$Type'], mod, name) }
        ensure
          mpr.close
        end
      end

      def qualified_document_name(type, mod, name)
        return name if %w[Projects$Module Projects$ModuleImpl].include?(type)

        mod && !name.empty? ? "#{mod}.#{name}" : name
      end

      def module_name(mpr, unit)
        visited = {}
        while unit && !visited[unit['UnitID']]
          visited[unit['UnitID']] = true
          document = mpr.parse_contents(unit)
          return document['Name'] if %w[Projects$Module Projects$ModuleImpl].include?(document['$Type'])

          unit = mpr.unit(unit['ContainerID'])
        end
        nil
      end

      def source_paths # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
        directories = [@document[:module] ? "modules/#{@document[:module]}" : 'app']
        found = directory_entries('.mxrb').filter_map do |entry|
          entry[:path] if entry[:name] == 'native_units.rb' && !entry[:directory]
        end
        visited = 0
        until directories.empty?
          @context.check!
          directory_entries(directories.shift).each do |entry|
            next if entry[:name].start_with?('.')

            visited += 1
            raise ArgumentError, 'Ruby document lookup exceeds 10000 entries' if visited > MAXIMUM_FILES

            if entry[:directory]
              directories << entry[:path]
            elsif entry[:path].end_with?('.rb')
              found << entry[:path]
            end
          end
        end
        found
      end

      def directory_entries(path)
        @files.list(path)
      rescue Errno::ENOENT, Errno::ENOTDIR
        []
      end

      def candidates(path)
        @context.check!
        # Only file-level declarations belong to the module loader. Calls in
        # method bodies, classes and unrelated blocks are not document claims.
        source_nodes(path).filter_map do |node|
          next unless matching_declaration?(node)

          { path:, line: node.location.start_line }
        end
      end

      def matching_declaration?(node) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/MethodLength
        return false unless node.is_a?(Prism::CallNode) && node.receiver.nil?
        return same_id?(literal_argument(node), @document[:unit_id]) if node.name == :native_unit

        options = keyword_options(node)
        identifier = literal(options['unit_id'])
        return false if options.key?('unit_id') && !same_id?(identifier, @document[:unit_id])
        if node.name == :native_document
          return same_id?(identifier, @document[:unit_id]) && literal(options['type']) == @document[:type] &&
                 (@document[:name].empty? || literal_argument(node) == @document[:name])
        end
        return true if GLOBAL_DECLARATIONS.fetch(@document[:type], []).include?(node.name.to_s)
        return false unless literal_argument(node) == @document[:name]
        return false unless node.name.to_s == DECLARATIONS[@document[:type]]

        !@document[:type].start_with?('Microflows$') || identifier || flow_metadata_matches?
      end

      def source_nodes(path)
        @context.check!
        parsed = parsed_source(path)
        parsed&.success? ? parsed.value.statements.body : []
      end

      # A file removed after the directory listing is simply not a declaration.
      def parsed_source(path)
        @parsed_sources ||= {}
        return @parsed_sources[path] if @parsed_sources.key?(path)

        @parsed_sources[path] = begin
          Prism.parse(@files.read(path).fetch(:text))
        rescue Errno::ENOENT, Errno::ENOTDIR
          nil
        end
      end

      def keyword_options(node)
        arguments_of(node).grep(Prism::KeywordHashNode).flat_map(&:elements).filter_map do |entry|
          [literal(entry.key), entry.value] if entry.is_a?(Prism::AssocNode)
        end.to_h
      end

      def literal(node)
        node.unescaped if node.is_a?(Prism::SymbolNode) || node.is_a?(Prism::StringNode)
      end

      def flow_metadata_matches?
        metadata = flow_metadata
        entries = metadata.is_a?(Array) ? metadata : [metadata]
        typed = entries.select { _1.is_a?(Hash) && _1['native_type'] == @document[:type] }
        typed.one? && typed.first['unit_id'].is_a?(String) &&
          typed.first['unit_id'].downcase == @document[:unit_id].downcase
      end

      def flow_metadata
        @flow_metadata ||= JSON.parse(@files.read('.mxrb/semantic_metadata.json').fetch(:text))
        ['modules', @document[:module], 'flows', @document[:name]].reduce(@flow_metadata) do |value, key|
          value[key] if value.is_a?(Hash)
        end
      rescue Errno::ENOENT, Errno::ENOTDIR, JSON::ParserError
        false
      end
    end
  end
end
