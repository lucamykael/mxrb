# frozen_string_literal: true

require 'prism'
require_relative 'files'
require_relative 'ruby_project'
require_relative 'request_context'

module Mxrb
  module Studio
    # Resolves the saved native document's identity to a parsed Ruby declaration.
    # Filenames are not identities: users may move or rename their Ruby files.
    class RubyDocument # rubocop:disable Metrics/ClassLength
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
        'DatabaseConnector$DatabaseConnection' => 'database_connection'
      }.freeze
      SUPPORTED_TYPES = (DECLARATIONS.keys + Model::Module::EDITABLE_DOCUMENT_TYPES).freeze
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
        unless supported?
          return unavailable('unsupported_type', 'This document does not have a supported Ruby source view.')
        end

        representation = @project.status
        return result(state: 'missing_project') unless representation[:state] == 'ready'

        @files = Files.new(representation.fetch(:root))
        resolve_candidates
      end

      private

      def resolve_candidates
        matches = source_paths.flat_map { candidates(_1) }
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

      def supported? = SUPPORTED_TYPES.include?(@document[:type]) && @document[:module]

      def result(state:, **details)
        { state:, source_model: @project.source_model, root: @files&.root, path: nil, line: nil,
          **(@document || {}).except(:module), **details }
      end

      def unavailable(reason, message) = result(state: 'unavailable', reason:, message:)

      def native_document(unit_id)
        mpr = IO::MprFile.open(@project.source_model, readonly: true, apply_studio_compatibility: false)
        unit = mpr.unit(unit_id)
        return unless unit

        document = mpr.parse_contents(unit)
        mod = module_name(mpr, unit)
        name = document['Name'].to_s
        { unit_id: unit.fetch('UnitID'), type: document['$Type'], name:, module: mod,
          qualified_name: mod && !name.empty? ? "#{mod}.#{name}" : name }
      ensure
        mpr&.close
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
        directories = ["modules/#{@document.fetch(:module)}"]
        found = []
        visited = 0
        until directories.empty?
          @context.check!
          @files.list(directories.shift).each do |entry|
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
      rescue Errno::ENOENT, Errno::ENOTDIR
        []
      end

      def candidates(path)
        @context.check!
        parsed = Prism.parse(@files.read(path).fetch(:text))
        return [] if parsed.failure?

        # Only file-level declarations belong to the module loader. Calls in
        # method bodies, classes and unrelated blocks are not document claims.
        Array(parsed.value.statements&.body).filter_map do |node|
          next unless matching_declaration?(node)

          { path:, line: node.location.start_line }
        end
      rescue Errno::ENOENT, Errno::ENOTDIR
        []
      end

      def matching_declaration?(node) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
        return false unless node.is_a?(Prism::CallNode) && node.receiver.nil?
        return false unless literal(node.arguments&.arguments&.first) == @document[:name]

        options = keyword_options(node)
        identifier = literal(options['unit_id'])
        return false if options.key?('unit_id') && identifier&.downcase != @document[:unit_id].downcase
        if node.name == :native_document
          return identifier&.downcase == @document[:unit_id].downcase && literal(options['type']) == @document[:type]
        end
        return false unless node.name.to_s == DECLARATIONS[@document[:type]]

        !@document[:type].start_with?('Microflows$') || identifier || flow_metadata_matches?
      end

      def keyword_options(node)
        arguments = node.arguments&.arguments || []
        arguments.grep(Prism::KeywordHashNode).flat_map(&:elements).filter_map do |entry|
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
