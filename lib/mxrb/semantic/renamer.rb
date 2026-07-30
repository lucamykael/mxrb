# frozen_string_literal: true

module Mxrb
  module Semantic
    RenameChange = Data.define(:unit_id, :artifact, :path, :before, :after)

    # Immutable preview plus the prepared BSON documents needed for an explicit
    # apply. Construct plans through Project#plan_rename.
    class RenamePlan
      attr_reader :source, :target, :changes, :documents

      def initialize(project:, source:, target:, changes:, documents:)
        @project = project
        @source = source
        @target = target
        @changes = changes.freeze
        @documents = documents.freeze
        @applied = false
      end

      def empty? = @changes.empty?
      def applied? = @applied
      def affected_units = @documents.keys.freeze

      def apply!
        raise ArgumentError, "rename plan was already applied" if @applied

        @project.mpr.transaction do
          @documents.each { |unit_id, document| @project.mpr.update_unit(unit_id, document) }
        end
        @project.refresh!
        @applied = true
        self
      end
    end

    # Plans and applies model-wide renames without introducing a query
    # language. Every changed BSON string is visible in the Ruby preview.
    class Renamer
      METADATA_FIELDS = %w[Documentation documentation Caption caption Text text].freeze

      def initialize(project)
        @project = project
      end

      def plan(source_name, to:, cross_module: false)
        source = resolve(source_name)
        target = qualified_target(source, to, cross_module: cross_module)
        reject_collision(source, target)

        changes = []
        documents = {}
        @project.all_units.each do |raw|
          original = @project.parse_bson(raw)
          transformed = transform(
            original, source:, target:, unit_id: raw.fetch("UnitID"),
            target_unit: source.unit_id == raw.fetch("UnitID"), changes:
          )
          documents[raw.fetch("UnitID")] = transformed unless transformed.equal?(original)
        end

        RenamePlan.new(
          project: @project, source:, target:, changes:, documents:
        )
      end

      private

      def resolve(name)
        artifact = @project.find_artifact(name)
        return artifact if artifact

        matches = @project.semantic_index.find_all(name)
        raise KeyError, "unknown Mendix artifact #{name.inspect}" if matches.empty?

        kinds = matches.map(&:kind).uniq.join(", ")
        raise ArgumentError, "ambiguous Mendix artifact #{name.inspect} (#{kinds})"
      end

      def qualified_target(source, value, cross_module: false)
        requested = value.to_s
        raise ArgumentError, "new name cannot be empty" if requested.empty?
        unless requested.match?(/\A[A-Za-z_][A-Za-z0-9_.]*\z/)
          raise ArgumentError, "invalid Mendix name #{requested.inspect}"
        end

        old_parts = source.qualified_name.split(".")
        new_parts = requested.split(".")
        target = if new_parts.one?
                   (old_parts[0...-1] + new_parts).join(".")
                 else
                   requested
                 end
        unless target.split(".").length == old_parts.length
          raise ArgumentError, "#{source.kind} rename must keep its qualification depth"
        end
        if !cross_module && old_parts.length > 1 && target.split(".")[0...-1] != old_parts[0...-1]
          raise ArgumentError, "#{source.kind} rename cannot move the artifact to another container"
        end
        target
      end

      def reject_collision(source, target)
        collisions = @project.semantic_index.find_all(target)
                             .reject { _1.id == source.id }
        return if collisions.empty?

        raise ArgumentError, "Mendix artifact #{target.inspect} already exists"
      end

      def transform(
        value, source:, target:, unit_id:, target_unit:, changes:, path: [],
        target_object: false
      )
        case value
        when Hash
          transformed_hash(
            value, source:, target:, unit_id:, target_unit:, changes:, path:,
            target_object:
          )
        when Array
          transformed_array(
            value, source:, target:, unit_id:, target_unit:, changes:, path:,
            target_object:
          )
        when String
          transformed_string(
            value, source:, target:, target_object:, field: path.last
          ).tap do |replacement|
            next if replacement == value

            changes << RenameChange.new(
              unit_id, source, path.map(&:to_s).freeze, value, replacement
            )
          end
        else
          value
        end
      end

      def transformed_hash(value, **context)
        object_id = IO::BsonCodec.extract_id(value["$ID"])
        target_object = context.fetch(:target_unit) &&
                        object_id == artifact_object_id(context.fetch(:source))
        changed = false
        result = value.each_with_object({}) do |(key, child), hash|
          transformed = transform(
            child, **context, target_object:, path: context.fetch(:path) + [key]
          )
          changed ||= !transformed.equal?(child)
          hash[key] = transformed
        end
        changed ? result : value
      end

      def transformed_array(value, **context)
        changed = false
        result = value.each_with_index.map do |child, index|
          transformed = transform(
            child, **context, target_object: false,
            path: context.fetch(:path) + [index]
          )
          changed ||= !transformed.equal?(child)
          transformed
        end
        changed ? result : value
      end

      def transformed_string(value, source:, target:, target_object:, field:)
        return value if METADATA_FIELDS.include?(field.to_s)

        replacement = replace_qualified(value, source.qualified_name, target)
        return replacement unless replacement == value
        return value unless target_object && declaration_field?(field)

        value == source.name ? target.split(".").last : value
      end

      def artifact_object_id(artifact)
        artifact.id.sub(/\A(?:module|entity|attribute|association|unit):/, "")
      end

      def replace_qualified(value, source, target)
        pairs = [[source, target]]
        if source.count(".") == 2
          pairs << [source.sub(/\.[^.]+\z/, "/\\0").sub("/.", "/"),
                    target.sub(/\.[^.]+\z/, "/\\0").sub("/.", "/")]
        end
        pairs.reduce(value) do |current, (old_name, new_name)|
          current.gsub(
            /(?<![A-Za-z0-9_])#{Regexp.escape(old_name)}(?![A-Za-z0-9_])/,
            new_name
          )
        end
      end

      def declaration_field?(field)
        %w[Name name $QualifiedName].include?(field.to_s)
      end
    end
  end
end
