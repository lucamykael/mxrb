# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'securerandom'
require 'uri'

require_relative 'web_ui'
require_relative 'http/server'

module Mxrb
  # Browser ER diagram for Mendix domain models. It edits visual layout only:
  # entity locations plus local and cross-module connection anchors.
  # rubocop:disable Metrics
  module DomainDiagram
    ANCHORS = %w[north east south west].freeze
    ANCHOR_VALUES = {
      'north' => '50;0', 'east' => '100;50',
      'south' => '50;100', 'west' => '0;50'
    }.freeze
    VALUE_ANCHORS = ANCHOR_VALUES.invert.freeze

    # Builds a framework-neutral JSON projection from arbitrary Mendix modules.
    class Document
      def initialize(path, modules: [])
        @path = File.expand_path(path)
        @selected_modules = Array(modules).map(&:to_s)
      end

      def to_h
        Model::Project.open(@path).then do |project|
          selected = project.modules
          unless @selected_modules.empty?
            unknown = @selected_modules.uniq - selected.map(&:name)
            raise ArgumentError, "unknown modules: #{unknown.join(', ')}" unless unknown.empty?

            selected = selected.select { @selected_modules.include?(_1.name) }
          end
          anchor_overrides = project.mpr.domain_diagram_anchors
          known = project.modules.each_with_object({}) do |mod, names|
            mod.entities.each do |entity|
              qualified = entity.qualified_name || "#{mod.name}.#{entity.name}"
              names[entity.id] = qualified
              names[qualified] = qualified
            end
          end
          {
            project: { name: project.name, mendix_version: project.mendix_version },
            module_filter_applied: !@selected_modules.empty?,
            modules: selected.filter_map { module_payload(_1, known, anchor_overrides) }
          }
        ensure
          project&.close
        end
      end

      private

      def module_payload(mod, known, anchor_overrides = {})
        domain = mod.domain_model
        return unless domain

        raw = mod.mpr.parse_contents(mod.mpr.unit(domain.id))
        association_docs = array(raw['associations'] || raw['Associations']) +
                           array(raw['crossAssociations'] || raw['CrossAssociations'])
        association_by_id = association_docs.to_h { [IO::BsonCodec.extract_id(_1['$ID']), _1] }
        {
          id: mod.id, name: mod.name,
          entities: domain.entities.map { entity_payload(_1, mod.name) },
          associations: domain.associations.filter_map do |association|
            association_payload(
              association, association_by_id[association.id] || {}, known, anchor_overrides
            )
          end
        }
      end

      def entity_payload(entity, module_name)
        kind = if entity.respond_to?(:oql_view?) && entity.oql_view?
                 'oql_view'
               elsif entity.persistable == true
                 'entity'
               else
                 'dto'
               end
        {
          id: entity.id, name: entity.name,
          qualified_name: entity.qualified_name || "#{module_name}.#{entity.name}",
          module: module_name, kind:,
          persistent: entity.persistable == true,
          x: Integer(entity.location&.fetch(:x, 0) || 0),
          y: Integer(entity.location&.fetch(:y, 0) || 0),
          attributes: entity.attributes.map do |attribute|
            {
              name: attribute.name, type: attribute.type.to_s,
              required: attribute.required == true, key: attribute.unique == true
            }
          end
        }
      end

      def association_payload(association, raw, known, anchor_overrides = {})
        from = known[association.from_entity_id]
        to = known[association.to_entity_id]
        return unless from && to

        cross_module = raw['$Type'] == 'DomainModels$CrossAssociation'
        override = anchor_overrides.fetch(association.id.to_s, {})

        {
          id: association.id, name: association.name, from:, to:,
          type: association.association_type.to_s,
          owner: association.owner.to_s,
          source_anchor: override.fetch(
            :source_anchor, anchor(raw['ParentConnection'], fallback: 'east')
          ),
          target_anchor: override.fetch(
            :target_anchor, anchor(raw['ChildConnection'], fallback: 'west')
          ),
          cross_module:,
          editable_anchors: true,
          anchor_storage: cross_module ? 'mxrb' : 'native'
        }
      end

      def anchor(value, fallback:)
        VALUE_ANCHORS.fetch(value.to_s, fallback)
      end

      def array(value) = IO::BsonCodec.parse_array(value)[:items]
    end

    # Applies only audited visual fields to a copied MPR.
    class LayoutWriter
      def initialize(path)
        @path = File.expand_path(path)
      end

      def apply!(payload)
        modules = Array(payload.fetch('modules'))
        mpr = IO::MprFile.open(@path, readonly: false)
        changed = 0
        metadata_anchors = []
        mpr.transaction do
          module_units = mpr.units_by_containment('Modules').to_h do |unit|
            [mpr.parse_contents(unit)['Name'].to_s, unit]
          end
          modules.each do |layout|
            unit = module_units[layout.fetch('name').to_s]
            raise ValidationError, "domain module #{layout['name']} not found" unless unit

            module_changed, module_metadata = apply_module(mpr, unit, layout)
            changed += module_changed
            metadata_anchors.concat(module_metadata)
          end
          changed += mpr.write_domain_diagram_anchors(metadata_anchors)
        end
        changed
      ensure
        mpr&.close
      end

      private

      def apply_module(mpr, module_unit, layout)
        domain_unit = mpr.children_of(module_unit.fetch('UnitID')).find do |unit|
          unit['ContainmentName'] == 'DomainModel'
        end
        raise ValidationError, "domain model #{layout['name']} not found" unless domain_unit

        doc = mpr.parse_contents(domain_unit)
        changed = update_entities(doc, Array(layout['entities']))
        association_changes, metadata_anchors = update_associations(
          doc, Array(layout['associations'])
        )
        changed += association_changes
        mpr.update_unit(domain_unit.fetch('UnitID'), doc) if changed.positive?
        [changed, metadata_anchors]
      end

      def update_entities(doc, layouts)
        by_id = layouts.to_h { [_1.fetch('id').to_s, _1] }
        entities = array(doc['entities'] || doc['Entities'])
        native_ids = entities.map { IO::BsonCodec.extract_id(_1['$ID']).to_s }
        unknown = by_id.keys - native_ids
        raise ValidationError, "unknown domain entities: #{unknown.join(', ')}" unless unknown.empty?

        changed = entities.count do |entity|
          layout = by_id[IO::BsonCodec.extract_id(entity['$ID']).to_s]
          next false unless layout

          x = bounded_integer(layout.fetch('x'), 'x')
          y = bounded_integer(layout.fetch('y'), 'y')
          key = entity.key?('Location') ? 'Location' : 'location'
          value = entity[key].is_a?(Hash) ? { 'x' => x, 'y' => y } : "#{x};#{y}"
          changed = entity[key] != value
          entity[key] = value
          changed
        end
        key = doc.key?('Entities') ? 'Entities' : 'entities'
        doc[key] = IO::BsonCodec.build_array(entities)
        changed
      end

      def update_associations(doc, layouts)
        by_id = layouts.to_h { [_1.fetch('id').to_s, _1] }
        key = %w[associations Associations].find { doc.key?(_1) } || 'associations'
        cross_key = %w[crossAssociations CrossAssociations].find { doc.key?(_1) } ||
                    'crossAssociations'
        associations = array(doc[key])
        cross_associations = array(doc[cross_key])
        native_ids = associations.map { IO::BsonCodec.extract_id(_1['$ID']).to_s }
        cross_ids = cross_associations.map { IO::BsonCodec.extract_id(_1['$ID']).to_s }
        unknown = by_id.keys - native_ids - cross_ids
        raise ValidationError, "unknown domain associations: #{unknown.join(', ')}" unless unknown.empty?

        count = associations.count do |association|
          layout = by_id[IO::BsonCodec.extract_id(association['$ID']).to_s]
          next false unless layout

          source = connection(layout.fetch('source_anchor'))
          target = connection(layout.fetch('target_anchor'))
          changed = association['ParentConnection'] != source || association['ChildConnection'] != target
          association['ParentConnection'] = source
          association['ChildConnection'] = target
          changed
        end
        doc[key] = IO::BsonCodec.build_array(associations)
        metadata = cross_ids.filter_map do |id|
          layout = by_id[id]
          next unless layout

          {
            id:, source_anchor: anchor_name(layout.fetch('source_anchor')),
            target_anchor: anchor_name(layout.fetch('target_anchor'))
          }
        end
        [count, metadata]
      end

      def bounded_integer(value, name)
        number = Integer(value)
        raise ValidationError, "#{name} is outside the diagram canvas" unless number.between?(-100_000, 100_000)

        number
      end

      def connection(anchor)
        ANCHOR_VALUES.fetch(anchor_name(anchor))
      end

      def anchor_name(anchor)
        ANCHOR_VALUES.fetch(anchor.to_s) do
          raise ValidationError, "unknown association anchor #{anchor.inspect}"
        end
        anchor.to_s
      end

      def array(value) = IO::BsonCodec.parse_array(value)[:items]
    end

    # Loopback-only server for the standalone editor.
    class Server
      MAX_BODY_BYTES = 2_097_152
      LOOPBACK_HOSTS = %w[127.0.0.1 ::1 localhost].freeze

      attr_reader :source, :output, :host, :port, :managed_paths

      def initialize(source, output: nil, modules: [], host: '127.0.0.1', port: 4568, force: false,
                     reuse: false, lifecycle_token: nil)
        @source = File.expand_path(source)
        raise ArgumentError, "MPR not found: #{@source}" unless File.file?(@source)

        @output = File.expand_path(output || default_output)
        raise ArgumentError, 'output must be a safe copy, not the source MPR' if same_file_as_source?
        raise ArgumentError, "output cannot be a directory: #{@output}" if File.directory?(@output)
        raise ArgumentError, "output cannot be a symbolic link: #{@output}" if File.symlink?(@output)

        @host = host.to_s
        raise ArgumentError, 'domain model server must bind to loopback' unless LOOPBACK_HOSTS.include?(@host)

        @port = Integer(port)
        @modules = Array(modules)
        @token = SecureRandom.hex(24)
        @lifecycle_token = lifecycle_token
        @managed_paths = [@output]
        prepare_output(force:, reuse:)
      end

      def start
        @server = Http::Server.new(host:, port:) { dispatch(_1, _2) }
        @server.start { yield(_1) if block_given? }
      end

      def shutdown = @server&.shutdown

      private

      def default_output
        File.join(File.dirname(source), "#{File.basename(source, '.mpr')}.domain-layout.mpr")
      end

      def prepare_output(force:, reuse:)
        if reuse
          raise ArgumentError, "output not found: #{output}" unless File.file?(output)

          return
        end

        raise ArgumentError, "output already exists: #{output}; use --force" if File.exist?(output) && !force

        validate_external_contents_destination!
        FileUtils.mkdir_p(File.dirname(output))
        FileUtils.cp(source, output)
        copy_external_contents
      end

      def same_file_as_source?
        source == output || (File.exist?(output) && File.identical?(source, output))
      end

      def validate_external_contents_destination!
        source_contents = File.join(File.dirname(source), 'mprcontents')
        return unless File.directory?(source_contents)

        output_directory = File.dirname(output)
        return if File.expand_path(output_directory) == File.expand_path(File.dirname(source))

        target = File.join(output_directory, 'mprcontents')
        return unless File.exist?(target) || File.symlink?(target)

        raise ArgumentError, "external contents destination already exists: #{target}"
      end

      def copy_external_contents
        source_contents = File.join(File.dirname(source), 'mprcontents')
        return unless File.directory?(source_contents)

        output_directory = File.dirname(output)
        return if File.expand_path(output_directory) == File.expand_path(File.dirname(source))

        target = File.join(output_directory, 'mprcontents')
        FileUtils.cp_r(source_contents, output_directory)
        @managed_paths << target
      end

      def dispatch(request, response)
        if request.request_method == 'GET' && request.path == '/'
          return render(response, 200, WebUi.page('domain'), 'text/html; charset=utf-8')
        end

        if request.request_method == 'GET' && request.path.start_with?('/assets/')
          asset = WebUi.asset(request.path)
          return render(response, 200, *asset) if asset

          return json(response, 404, ok: false, error: 'not_found')
        end

        if request.request_method == 'GET' && request.path == '/api/diagram'
          payload = Document.new(output, modules: @modules).to_h.merge(
            output: output, csrf_token: @token
          )
          return json(response, 200, payload)
        end
        if request.path.start_with?('/api/admin/')
          return json(response, 403, ok: false, error: 'forbidden') unless lifecycle_authorized?(request)
          return json(response, 200, ok: true) if request.request_method == 'GET' && request.path == '/api/admin/status'

          if request.request_method == 'POST' && request.path == '/api/admin/shutdown'
            Thread.new { shutdown }
            return json(response, 200, ok: true)
          end
          return json(response, 404, ok: false, error: 'not_found')
        end
        if request.request_method == 'POST' && request.path == '/api/layout'
          raise ValidationError, 'invalid editor token' unless request['X-MXRB-Token'].to_s == @token

          body = request.body.to_s
          raise ValidationError, 'layout exceeds 2 MiB' if body.bytesize > MAX_BODY_BYTES

          changed = LayoutWriter.new(output).apply!(JSON.parse(body))
          return json(response, 200, ok: true, changed:, output:)
        end
        return json(response, 404, ok: false, error: 'not_found') if request.path.start_with?('/api/')

        json(response, 404, ok: false, error: 'not_found')
      rescue JSON::ParserError, ValidationError, KeyError, ArgumentError => e
        json(response, 422, ok: false, error: e.message)
      end

      def lifecycle_authorized?(request)
        @lifecycle_token && request['X-MXRB-Lifecycle-Token'].to_s == @lifecycle_token
      end

      def json(response, status, payload)
        render(response, status, JSON.generate(payload), 'application/json; charset=utf-8')
      end

      def render(response, status, body, type)
        response.status = status
        response['Content-Type'] = type
        response['Cache-Control'] = 'no-store'
        response['X-Content-Type-Options'] = 'nosniff'
        response.body = body
      end
    end
  end
  # rubocop:enable Metrics
end
