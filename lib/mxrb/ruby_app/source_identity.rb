# frozen_string_literal: true

module Mxrb
  module RubyApp
    # Document identities are private compilation metadata, scoped to the
    # application and source file currently being loaded.
    class SourceIdentity
      BUNDLE_PATH = '.mxrb/source-identities.json'
      THREAD_KEY = :mxrb_ruby_app_source_identity
      COLLECTIONS = {
        'models' => 'record', 'dtos' => 'record', 'constants' => 'constant',
        'enumerations' => 'enumeration', 'services' => 'service',
        'nanoflows' => 'service', 'pages' => 'page', 'scheduled_events' => 'scheduled_event',
        'regular_expressions' => 'regular_expression'
      }.freeze
      KINDS = (COLLECTIONS.values + %w[module_security project_security]).uniq.freeze
      FIELDS = %w[kind id name path ruby_class native_kind].freeze

      class << self
        def with(manifest)
          previous = Thread.current[THREAD_KEY]
          context = new(manifest)
          Thread.current[THREAD_KEY] = context
          yield context
          context
        ensure
          Thread.current[THREAD_KEY] = previous
        end

        def resolve(owner, kind, name, id: nil, renamed_from: nil)
          context = Thread.current[THREAD_KEY]
          context ? context.resolve(owner, kind.to_s, name.to_s, id:, renamed_from:) : id.to_s
        end

        def validate_flow!(owner, kind)
          Thread.current[THREAD_KEY]&.validate_flow!(owner, kind.to_s)
        end

        def class_name(owner)
          owner.name.to_s.sub(/\A#<Module:0x[0-9a-f]+>::/i, '')
        end

        def read_bundle(files)
          matches = Array(files).select { _1.fetch(:path) == BUNDLE_PATH }
          return [] if matches.empty?

          raise SerializationError, 'duplicate Ruby source identity sidecar' unless matches.one?

          file = matches.first
          contents = file.fetch(:contents)
          unless Digest::SHA256.hexdigest(contents) == file.fetch(:sha256)
            raise SerializationError, 'Ruby source identity sidecar checksum mismatch'
          end

          payload = JSON.parse(contents)
          unless payload.is_a?(Hash) && payload['format_version'] == 1 && payload['entries'].is_a?(Array)
            raise SerializationError, 'invalid Ruby source identity sidecar format'
          end

          entries = payload.fetch('entries').map { validate_entry(_1) }
          keys = entries.map { [_1.fetch('kind'), _1.fetch('id')] }
          raise SerializationError, 'duplicate Ruby source identities' unless keys.uniq.size == keys.size

          entries
        rescue JSON::ParserError => e
          raise SerializationError, "invalid Ruby source identity sidecar: #{e.message}"
        end

        private

        def validate_entry(entry)
          unless entry.is_a?(Hash) && FIELDS.all? { entry[_1].is_a?(String) } &&
                 KINDS.include?(entry['kind']) && !entry['id'].empty? && !entry['name'].empty? &&
                 entry['path'].match?(%r{\Aapp/(?:#{ARTIFACT_DIRECTORIES.join('|')})/.+\.rb\z})
            raise SerializationError, 'invalid Ruby source identity entry'
          end

          clean = Pathname.new(entry.fetch('path')).cleanpath.to_s
          unless clean == entry.fetch('path') && !clean.split('/').include?('..')
            raise SerializationError, 'unsafe Ruby source identity path'
          end
          if entry['kind'] == 'service' && !%w[microflow nanoflow].include?(entry['native_kind'])
            raise SerializationError, 'invalid Ruby service identity kind'
          end

          entry.slice(*FIELDS).freeze
        end
      end

      def initialize(manifest)
        @root = manifest.root
        @entries = manifest.modules.flat_map { module_entries(_1) }
        security = manifest.data['security']
        if security && security['path']
          @entries << {
            'kind' => 'project_security', 'id' => security.fetch('id').to_s,
            'name' => 'project', 'path' => security.fetch('path'),
            'ruby_class' => security.fetch('ruby_class', 'ApplicationSecurity').to_s, 'native_kind' => ''
          }
        end
        @security_identity = SecurityIdentity.new(manifest)
        @record_identity = RecordIdentity.new(manifest)
        @by_path = @entries.group_by { _1.fetch('path') }
        @by_identity = @entries.group_by { [_1.fetch('kind'), _1.fetch('id')] }
        @by_class = @entries.group_by { [_1.fetch('kind'), _1.fetch('ruby_class')] }
        @by_name = @entries.group_by { [_1.fetch('kind'), _1.fetch('name')] }
        @enumeration_values = manifest.modules.flat_map { Array(_1['enumerations']) }
                                      .to_h do |entry|
          unless entry['values'].is_a?(Array)
            raise ValidationError, 'existing Ruby enumeration requires its member identity baseline'
          end

          [entry.fetch('id').to_s, entry.fetch('values')]
        end
        @bindings = {}
        @claims = {}
        @names = {}
        @new_declarations = {}
        @matched_entries = {}.compare_by_identity
        @renames = {}.compare_by_identity
      end

      def load_file(path)
        previous = @source_path
        @source_path = Pathname.new(File.expand_path(path)).relative_path_from(Pathname.new(@root)).to_s
        yield
      ensure
        @source_path = previous
      end

      def resolve(owner, kind, name, id: nil, renamed_from: nil)
        raise ValidationError, 'Ruby source identity requires a source file context' unless @source_path

        name_key = [kind, name]
        if kind != 'service' && @names[name_key] && !@names[name_key].equal?(owner)
          raise ValidationError, "duplicate Ruby #{kind} declaration: #{name}"
        end

        entry = renamed_entry(kind, name, id, renamed_from) if renamed_from
        entry ||= if id.to_s.empty?
                    implicit_entry(owner, kind, name)
                  else
                    unique_entry(@by_identity.fetch([kind, id.to_s], []))
                  end
        identifier = id.to_s.empty? ? entry.to_h.fetch('id', '') : id.to_s
        key = [kind, identifier]
        previous = @claims[key] unless identifier.empty?
        if previous && !previous.equal?(owner)
          raise ValidationError, "Ruby declarations claim the same #{kind} identity: #{name}"
        end

        @claims[key] = owner unless identifier.empty?
        @matched_entries[entry] = true if entry
        if entry.nil? && id.to_s.empty?
          @new_declarations[owner] = @source_path
        else
          @new_declarations.delete(owner)
        end
        @names[name_key] = owner
        @renames[owner] = renamed_from.to_s if renamed_from
        @bindings[owner] = {
          'kind' => kind, 'id' => identifier, 'name' => name, 'path' => @source_path,
          'ruby_class' => self.class.class_name(owner),
          'native_kind' => entry.to_h.fetch('native_kind', '')
        }
        identifier
      end

      def validate_flow!(owner, kind)
        binding = @bindings[owner]
        return unless binding

        existing = binding.fetch('native_kind')
        unless existing.empty? || existing == kind
          raise ValidationError, 'an existing Ruby flow cannot change between microflow and nanoflow'
        end

        binding['native_kind'] = kind
      end

      def rebase_member_identities!(project)
        @enumeration_values = project.modules.flat_map do |mod|
          mod.enumerations.map do |enumeration|
            identifier = IO::BsonCodec.extract_id(enumeration['$ID']).to_s
            values = IO::BsonCodec.parse_array(enumeration['Values']).fetch(:items).map do |value|
              {
                'name' => value['Name'].to_s,
                'id' => IO::BsonCodec.extract_id(value['$ID']).to_s
              }
            end
            [identifier, values]
          end
        end.to_h
        self
      end

      def bundle
        entries = @bindings.filter_map do |owner, binding|
          identifier = binding.fetch('id')
          next if identifier.empty?

          binding.merge('id' => identifier, 'name' => owner.mendix_name.to_s)
        end
        contents = JSON.pretty_generate('format_version' => 1, 'entries' => entries) << "\n"
        { path: BUNDLE_PATH, contents:, sha256: Digest::SHA256.hexdigest(contents), mode: 0o600 }
      end

      def finalize!
        validate_new_declarations!
        @bindings.each do |owner, binding|
          case binding.fetch('kind')
          when 'record'
            owner.resolve_record_identities!(@record_identity)
          when 'enumeration'
            owner.resolve_value_identities!(@enumeration_values.fetch(binding.fetch('id'), []))
          when 'module_security', 'project_security'
            owner.resolve_security_identities!(@security_identity)
          end
        end
        self
      end

      # Newly authored documents receive their native IDs during writing.
      # Capture those IDs before embedding, including custom source locations.
      def reconcile!(project)
        entries = project.modules.flat_map { materialized_entries(_1) }
        entries.concat(project_security_entries(project)) if @bindings.values.any? { _1['kind'] == 'project_security' }
        materialized = entries.group_by { [_1.fetch('kind'), _1.fetch('name'), _1.fetch('native_kind')] }
        @bindings.each do |owner, binding|
          key = [binding.fetch('kind'), owner.mendix_name.to_s, binding.fetch('native_kind')]
          matches = materialized.fetch(key, [])
          if matches.size > 1
            matches = matches.select { _1['id'] == owner.mendix_id.to_s }
            raise ValidationError, "ambiguous materialized Ruby identity for #{key[1]}" unless matches.one?
          end
          if matches.empty?
            raise ValidationError, "missing materialized Ruby identity for #{key[1]}" \
              if !binding['id'].empty? && @by_identity.key?([key[0], binding['id']])

            binding['id'] = ''
            next
          end

          identifier = matches.first.fetch('id')
          original = binding['id'].empty? ? nil : unique_entry(@by_identity.fetch([key[0], binding['id']], []))
          if original && original['id'] != identifier
            raise ValidationError, "materialized Ruby identity changed for #{key[1]}"
          end

          binding['id'] = identifier
        end
        self
      end

      def validate_entity_names!
        @bindings.each do |owner, binding|
          next unless binding['kind'] == 'record' && !binding['id'].empty?

          original = unique_entry(@by_identity.fetch(['record', binding['id']], []))
          next unless original && original['name'] != binding['name']
          next if @renames[owner] == original['name']

          raise ValidationError,
                "Ruby entity rename #{original['name']} -> #{binding['name']} requires an explicit semantic rename; " \
                'automatic delete-and-create is not supported'
        end
      end

      private

      def renamed_entry(kind, name, id, renamed_from)
        raise ValidationError, 'renamed_from is supported only for Ruby records' unless kind == 'record'

        previous_name = renamed_from.to_s
        raise ValidationError, 'record renamed_from cannot be empty' if previous_name.empty?
        raise ValidationError, 'record renamed_from must differ from the new name' if previous_name == name

        entry = unique_entry(@by_name.fetch([kind, previous_name], []))
        raise ValidationError, "unknown Ruby record rename source #{previous_name}" unless entry
        unless id.to_s.empty? || id.to_s == entry.fetch('id')
          raise ValidationError, 'explicit record identity conflicts with renamed_from'
        end

        entry
      end

      # A declaration without a match never borrows an existing identity. Wait
      # until all source files have loaded before deciding whether it is a new
      # document: an existing declaration may appear later, or move elsewhere.
      def validate_new_declarations!
        @new_declarations.each_value do |path|
          previous = @by_path.fetch(path, [])
          next unless previous.any? { !@matched_entries.key?(_1) }

          raise ValidationError,
                "cannot distinguish a new declaration from a rename in #{path}; " \
                'preserve its Ruby class or Mendix name, or supply its legacy id'
        end
      end

      def project_security_entries(project)
        project.mpr.children_of(project.mpr.root_unit.fetch('UnitID')).filter_map do |unit|
          next unless unit['ContainmentName'] == 'ProjectDocuments'

          document = project.parse_bson(unit)
          next unless document['$Type'] == 'Security$ProjectSecurity'

          identifier = IO::BsonCodec.extract_id(document['$ID']).to_s
          identifier = unit.fetch('UnitID').to_s if identifier.empty?
          { 'kind' => 'project_security', 'name' => 'project', 'id' => identifier, 'native_kind' => '' }
        end
      end

      def materialized_entries(mod)
        entries = []
        add = lambda do |kind, name, id, native_kind = ''|
          entries << { 'kind' => kind, 'name' => name, 'id' => id.to_s, 'native_kind' => native_kind }
        end
        mod.entities.each { add.call('record', "#{mod.name}.#{_1.name}", _1.id) }
        mod.pages.each { add.call('page', "#{mod.name}.#{_1.name}", _1.id) }
        { 'microflow' => mod.microflows, 'nanoflow' => mod.nanoflows }.each do |kind, flows|
          flows.each { add.call('service', "#{mod.name}.#{_1.name}", _1.id, kind) }
        end
        { 'constant' => mod.constants, 'enumeration' => mod.enumerations,
          'scheduled_event' => mod.scheduled_events }.each do |kind, documents|
          documents.each do |document|
            add.call(kind, "#{mod.name}.#{document['Name']}", IO::BsonCodec.extract_id(document['$ID']))
          end
        end
        add.call('module_security', mod.name, mod.module_security_id)
        mod.domain_documents.each do |document|
          next unless document[:type] == RegularExpression::TYPE

          add.call('regular_expression', "#{mod.name}.#{document[:name]}", document[:id])
        end
        entries
      end

      def module_entries(mod)
        entries = COLLECTIONS.flat_map do |collection, kind|
          Array(mod[collection]).filter_map do |entry|
            path = entry[collection == 'nanoflows' ? 'ruby_path' : 'path']
            next if path.to_s.empty?

            {
              'kind' => kind, 'id' => entry.fetch('id').to_s, 'name' => entry.fetch('name').to_s,
              'path' => path.to_s, 'ruby_class' => entry.fetch('ruby_class', '').to_s,
              'native_kind' => if kind == 'service'
                                 collection == 'nanoflows' ? 'nanoflow' : 'microflow'
                               else
                                 ''
                               end
            }
          end
        end
        if (security = mod['module_security']) && security['path']
          entries << {
            'kind' => 'module_security', 'id' => security.fetch('id').to_s,
            'name' => mod.fetch('name').to_s, 'path' => security.fetch('path').to_s,
            'ruby_class' => security.fetch('ruby_class', '').to_s, 'native_kind' => ''
          }
        end
        entries
      end

      def implicit_entry(owner, kind, name)
        in_file = @by_path.fetch(@source_path, [])
        ruby_class = self.class.class_name(owner)
        candidates = in_file.select { _1['kind'] == kind && _1['ruby_class'] == ruby_class && !ruby_class.empty? }
        candidates = in_file.select { _1['kind'] == kind && _1['name'] == name } if candidates.empty?
        return unique_entry(candidates) unless candidates.empty?

        if in_file.any? { _1['ruby_class'] == ruby_class && !ruby_class.empty? && _1['kind'] != kind }
          raise ValidationError, "Ruby source cannot change document family in #{@source_path}"
        end

        candidates = ruby_class.empty? ? [] : @by_class.fetch([kind, ruby_class], [])
        return unique_entry(candidates) unless candidates.empty?

        if @by_name.key?([kind, name])
          raise ValidationError,
                "cannot resolve moved Ruby declaration #{name}; preserve its Ruby class or supply its legacy id"
        end
        nil
      end

      def unique_entry(entries)
        raise ValidationError, 'ambiguous Ruby source identity; preserve its source path or supply its legacy id' \
          if entries.size > 1

        entries.first
      end
    end
  end
end
