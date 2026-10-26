# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'tmpdir'
require_relative '../../mxrb'
require_relative 'snapshot'

# rubocop:disable Metrics
module Mxrb
  module Studio
    # Structural domain edits use the public semantic planners, independently of
    # the native IDE. Callers must explicitly identify their working-copy root.
    # The revision covers every native unit: incoming references outside the
    # edited module therefore invalidate a preview too. As with Documents,
    # cross-process CAS requires writers to cooperate with the Studio lock.
    class ModelOperations
      SUPPORTED = %w[add_attribute change_attribute remove_attribute add_entity remove_entity].freeze
      ATTRIBUTE_TYPES = (Model::Attribute::TYPE_MAP.keys - [:enum]).freeze
      ATTRIBUTE_FIELDS = %w[type default documentation required unique length localize_date].freeze
      IDENTIFIER = /\A[A-Za-z_][A-Za-z0-9_]*\z/
      attr_reader :model_path, :workspace_root

      def initialize(model_path, workspace_root:, source_model: nil)
        @workspace_root = File.realpath(workspace_root)
        @model_path = File.realpath(model_path)
        raise ArgumentError, 'workspace root must be a directory' unless File.directory?(@workspace_root)
        raise ArgumentError, 'model must be a file' unless File.file?(@model_path)
        unless @model_path.start_with?(@workspace_root + File::SEPARATOR)
          raise ArgumentError, 'model must be inside the explicit working-copy root'
        end
        return unless source_model && File.identical?(source_model, @model_path)

        raise ArgumentError, 'structural operations require a working copy, not the source model'
      end

      def capabilities
        { supported: SUPPORTED, attribute_types: ATTRIBUTE_TYPES.map(&:to_s),
          unsupported: {
            add_association: 'no public transactional association planner',
            change_association: 'no public transactional association planner',
            remove_association: 'no public transactional association planner',
            change_generalization: 'no public transactional inheritance planner',
            enum_attribute: 'enumeration reference validation is not implemented here',
            calculated_attribute: 'calculation signature validation is not implemented here'
          } }
      end

      def revision
        with_project { fingerprint(_1) }
      end

      def preview(operation, revision:)
        definition = normalize(operation)
        with_project { check_revision(_1, revision) }
        Dir.mktmpdir('mxrb-model-preview-') do |directory|
          copy = Snapshot.new(model_path, destination_root: directory).create
          with_project(copy.fetch(:model), readonly: false) do |project|
            check_revision(project, revision)
            plan = build_plan(project, definition)
            result = representation(project, plan, definition, revision)
            if result.fetch(:safe)
              baseline = Mxrb.validate(copy.fetch(:model))
              plan.apply!
              validation = Mxrb.validate(copy.fetch(:model))
              introduced = validation.errors - baseline.errors
              unless introduced.empty?
                raise ArgumentError,
                      "operation introduces integrity errors: #{introduced.join('; ')}"
              end

              result[:validation] = { errors: validation.errors, warnings: validation.warnings }
            end
            result
          end
        end
      end

      def apply(operation, revision:)
        definition = normalize(operation)
        proposal = preview(definition, revision:)
        raise ArgumentError, 'operation has incoming references; inspect preview before applying' unless proposal[:safe]

        with_lock do
          with_project(model_path, readonly: false) do |project|
            check_revision(project, revision)
            plan = build_plan(project, definition)
            raise ArgumentError, 'operation has incoming references' if plan.respond_to?(:safe?) && !plan.safe?

            plan.apply! # Each public planner owns its V1/V2 rollback transaction.
            proposal.merge(applied: true, revision: fingerprint(project))
          end
        end
      end

      private

      def with_project(path = model_path, readonly: true)
        unless File.realpath(model_path) == model_path && model_path.start_with?("#{File.realpath(workspace_root)}/")
          raise ArgumentError, 'working-copy path changed outside its root'
        end

        mpr = IO::MprFile.open(path, readonly:, apply_studio_compatibility: false)
        project = Model::Project.new(mpr)
        yield project
      ensure
        project&.close
      end

      def fingerprint(project)
        digest = Digest::SHA256.new
        digest.update(Marshal.dump([project.format_version, project.mendix_version]))
        # Include containment/hash metadata as well as actual content bytes;
        # stored ContentsHash alone is insufficient for split native storage.
        project.all_units.sort_by { _1.fetch('UnitID') }.each do |unit|
          digest.update(Marshal.dump(unit.reject { |key, _| key == 'Contents' }))
          bytes = project.mpr.content_bytes(unit)
          raise IncompletePackageError, "unit #{unit.fetch('UnitID')} has no content bytes" unless bytes

          digest.update([bytes.bytesize].pack('Q<')).update(bytes)
        end
        digest.hexdigest
      end

      def check_revision(project, expected)
        return if expected.is_a?(String) && expected.match?(/\A[0-9a-f]{64}\z/) && fingerprint(project) == expected

        raise Conflict, 'model changed after preview; both versions are preserved'
      end

      def normalize(operation)
        raise ArgumentError, 'operation must be an object' unless operation.is_a?(Hash)

        definition = operation.to_h { |key, value| [key.to_s, value] }
        kind = definition.fetch('operation') { raise ArgumentError, 'operation is required' }
        raise ArgumentError, "unsupported structural operation: #{kind}" unless SUPPORTED.include?(kind)

        fields = case kind
                 when 'add_attribute' then %w[operation target name] + ATTRIBUTE_FIELDS
                 when 'change_attribute' then %w[operation target] + ATTRIBUTE_FIELDS
                 when 'add_entity' then %w[operation target name documentation non_persistent attributes]
                 else %w[operation target]
                 end
        unknown = definition.keys - fields
        raise ArgumentError, "unsupported fields: #{unknown.join(', ')}" unless unknown.empty?

        target = definition['target']
        pattern = case kind
                  when 'add_entity' then /\A[A-Za-z_][A-Za-z0-9_]*\z/
                  when 'remove_attribute', 'change_attribute'
                    %r{\A[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*/[A-Za-z_][A-Za-z0-9_]*\z}
                  else /\A[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*\z/
                  end
        raise ArgumentError, 'invalid qualified target name' unless target.is_a?(String) && target.match?(pattern)

        if kind.start_with?('add_') && !(definition['name'].is_a?(String) &&
                                                                definition['name'].match?(IDENTIFIER))
          raise ArgumentError, 'invalid new member name'
        end

        if kind == 'add_entity'
          boolean!(definition, 'non_persistent')
          text!(definition, 'documentation')
          attrs = definition.fetch('attributes', [])
          raise ArgumentError, 'attributes must be an array' unless attrs.is_a?(Array)

          definition['attributes'] = attrs.map do |attribute|
            raise ArgumentError, 'attribute must be an object' unless attribute.is_a?(Hash)

            normalize(attribute.merge('operation' => 'add_attribute', 'target' => "#{target}.#{definition['name']}"))
              .reject { |key, _| %w[operation target].include?(key) }
          end
          names = definition['attributes'].map { _1.fetch('name').downcase }
          raise ArgumentError, 'duplicate new attribute names' unless names.uniq == names
        elsif kind.end_with?('attribute') && kind != 'remove_attribute'
          validate_attribute!(definition)
          if kind == 'change_attribute' && (definition.keys & ATTRIBUTE_FIELDS).empty?
            raise ArgumentError, 'select at least one attribute change'
          end
        end
        definition
      end

      def validate_attribute!(definition)
        if definition.key?('type') && !ATTRIBUTE_TYPES.map(&:to_s).include?(definition['type'].to_s)
          raise ArgumentError, "unsupported attribute type: #{definition['type']}"
        end

        %w[required unique localize_date].each { boolean!(definition, _1) }
        %w[documentation default].each { text!(definition, _1, nullable: _1 == 'default') }
        type = definition.fetch('type', 'string').to_s
        if definition['operation'] == 'add_attribute' && definition.key?('length') && type != 'string'
          raise ArgumentError, 'length applies only to string attributes'
        end
        if definition['operation'] == 'add_attribute' && definition.key?('localize_date') && type != 'datetime'
          raise ArgumentError, 'localize_date applies only to datetime attributes'
        end
        return unless definition.key?('length')
        return if definition['length'].is_a?(Integer) && definition['length'].between?(1, 2_147_483_647)

        raise ArgumentError, 'length must be a positive 32-bit integer'
      end

      def boolean!(definition, key)
        return unless definition.key?(key)
        return if [true, false].include?(definition[key])

        raise ArgumentError, "#{key} must be a boolean"
      end

      def text!(definition, key, nullable: false)
        return unless definition.key?(key)

        value = definition[key]
        return if nullable && value.nil?
        if value.is_a?(String) && value.encoding == Encoding::UTF_8 && value.valid_encoding? && !value.include?("\0")
          return
        end

        raise ArgumentError, "#{key} must be UTF-8 text"
      end

      def build_plan(project, definition)
        operation = definition.fetch('operation')
        target = definition.fetch('target')
        options = definition.reject { |key, _| %w[operation target].include?(key) }.transform_keys(&:to_sym)
        options[:type] = options[:type].to_sym if options.key?(:type)
        if options[:attributes]
          options[:attributes] = options[:attributes].map do |attribute|
            attribute.transform_keys(&:to_sym).tap { _1[:type] = _1.fetch(:type, :string).to_sym }
          end
        end
        validate_target!(project, definition, options)
        project.public_send("plan_#{operation}", target, **options)
      end

      def validate_target!(project, definition, options)
        kind = definition.fetch('operation')
        if kind == 'add_entity'
          mod = project.modules.find { _1.name == definition.fetch('target') }
          raise ArgumentError, 'unknown module' unless mod
          if mod.entities.any? { _1.name.casecmp?(options.fetch(:name)) }
            raise ArgumentError, 'entity already exists in the module'
          end

          return
        end

        target = definition.fetch('target')
        entity_name, attribute_name = target.split('/', 2)
        entity = project.entities.find { _1.qualified_name == entity_name }
        raise ArgumentError, "unknown entity: #{entity_name}" unless entity
        raise ArgumentError, 'OQL view entities require a projection-specific writer' if entity.oql_view?

        if kind == 'remove_entity'
          blocked = entity.attributes.any? { !project.references_to("#{entity_name}.#{_1.name}").empty? }
          raise ArgumentError, 'entity attributes have incoming references' if blocked

          return
        end
        attribute = entity.attributes.find { _1.name == attribute_name } if attribute_name
        raise ArgumentError, "unknown attribute: #{target}" if attribute_name && !attribute

        if kind == 'add_attribute'
          current = entity
          visited = []
          while current && !visited.include?(current.id)
            visited << current.id
            if current.attributes.any? { _1.name.casecmp?(options.fetch(:name)) }
              raise ArgumentError, 'attribute already exists locally or on an ancestor'
            end

            current = project.entities.find { _1.qualified_name == current.generalization_target }
          end
        end
        type = options.fetch(:type) { attribute ? attribute.type : :string }
        raise ArgumentError, 'length applies only to string attributes' if options.key?(:length) && type != :string
        if options.key?(:localize_date) && type != :datetime
          raise ArgumentError, 'localize_date applies only to datetime attributes'
        end
        return unless kind == 'change_attribute' && options.key?(:type) && attribute.type != type
        return if project.references_to("#{entity_name}.#{attribute_name}").empty?

        raise ArgumentError, 'cannot change the type of an attribute with incoming references'
      end

      def representation(_project, plan, definition, revision)
        incoming = if plan.respond_to?(:incoming)
                     plan.incoming.map do |reference|
                       { source: reference.source.qualified_name, target: reference.target.qualified_name,
                         relation: reference.relation.to_s, path: reference.path, value: reference.value }
                     end
                   else
                     []
                   end
        { operation: definition, revision:, applied: false,
          safe: !plan.respond_to?(:safe?) || plan.safe?, changes: plan.changes, incoming: }
      end

      def with_lock(&) = WriteLock.synchronize(model_path, &)
    end
  end
end
# rubocop:enable Metrics
