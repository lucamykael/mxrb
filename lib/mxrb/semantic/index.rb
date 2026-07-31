# frozen_string_literal: true

require "digest"
require "json"
require_relative "vec_store"

module Mxrb
  module Semantic
    Artifact = Data.define(
      :id, :qualified_name, :kind, :module_name, :name, :unit_id, :path, :metadata
    )

    Reference = Data.define(
      :source, :target, :relation, :path, :value
    )
    UnresolvedReference = Data.define(
      :source, :qualified_name, :expected_kinds, :path, :value
    )

    Impact = Data.define(:root, :artifacts, :references) do
      def empty? = artifacts.empty?
    end
    ArtifactDetails = Data.define(:artifact, :incoming, :outgoing)
    SemanticSearchHit = Data.define(:artifact, :distance)

    # Builds a semantic index directly from an opened MPR. Ruby is the public
    # API; the CLI only formats these results.
    class Index
      CACHE_VERSION = 3
      CACHE_METADATA_KEYS = %i[
        allowed_roles bson_type documentation excluded exposed from mark_as_used to
      ].freeze

      FIELD_RELATIONS = {
        "microflow" => :calls,
        "nanoflow" => :calls,
        "javaaction" => :calls,
        "javascriptaction" => :calls,
        "workflow" => :calls,
        "form" => :opens,
        "page" => :opens,
        "layout" => :uses_layout,
        "snippet" => :uses_snippet,
        "entity" => :uses_entity,
        "attribute" => :uses_attribute,
        "association" => :uses_association,
        "enumeration" => :uses_enumeration
      }.freeze

      CALL_KINDS = %i[microflow nanoflow java_action javascript_action workflow].freeze
      TOKEN = /[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*){1,2}/
      MEMBER_TOKEN = /[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*\/[A-Za-z_][A-Za-z0-9_]*/

      attr_reader :artifacts, :references, :unresolved_references

      def self.fingerprint(project)
        rows = project.query(
          "SELECT UnitID, ContainerID, ContainmentName, ContentsHash " \
          "FROM Unit ORDER BY UnitID"
        )
        digest = Digest::SHA256.new
        digest << CACHE_VERSION.to_s
        rows.each do |row|
          row.each do |value|
            bytes = value.to_s.b
            digest << [bytes.bytesize].pack("Q>") << bytes
          end
        end
        digest.hexdigest
      rescue StandardError
        nil
      end

      def initialize(project)
        @project = project
        reset_state
        @fingerprint = compute_fingerprint
        json = @fingerprint && @project.mpr.read_index_cache(@fingerprint)
        unless json && restore_from_cache(json)
          reset_state
          build
          @project.mpr.write_index_cache(@fingerprint, serialize_to_cache) if @fingerprint
        end
      end

      def find(name, kind: nil)
        return name if name.is_a?(Artifact)

        matches = @by_name[name.to_s]
        matches = matches.select { _1.kind == kind.to_sym } if kind
        matches.one? ? matches.first : nil
      end

      def find_all(name)
        @by_name[name.to_s].dup
      end

      def search(query, kind: nil, module_name: nil)
        matcher = query.is_a?(Regexp) ? query : /#{Regexp.escape(query.to_s)}/i
        @artifacts.select do |artifact|
          matcher.match?(artifact.qualified_name) &&
            (!kind || artifact.kind == kind.to_sym) &&
            (!module_name || artifact.module_name == module_name.to_s)
        end.sort_by { [_1.module_name.to_s, _1.kind.to_s, _1.qualified_name] }
      end

      # Semantic similarity search with optional sqlite-vec acceleration.
      def semantic_search(query, limit: 10, backend: :auto)
        semantic_search_hits(query, limit:, backend:).map(&:artifact).freeze
      end
      alias semantic_search_artifacts semantic_search

      def semantic_search_hits(query, limit: 10, backend: :auto)
        size = Integer(limit)
        raise ArgumentError, "semantic search limit must be positive" unless size.positive?

        embedder = semantic_embedder(backend)
        store = vec_store(embedder)
        return ruby_semantic_hits(query, embedder, size) unless store

        begin
          store.rebuild!(@artifacts) unless store.compatible?
          store.search(query, limit: size).filter_map do |hit|
            artifact = @by_id[hit[:id]]
            SemanticSearchHit.new(artifact, cosine_distance(hit[:distance])) if artifact
          end.freeze
        rescue SQLite3::Exception, LoadError
          ruby_semantic_hits(query, embedder, size)
        end
      end

      def describe(artifact)
        resolved = resolve_argument(artifact)
        ArtifactDetails.new(
          resolved,
          references_to(resolved).freeze,
          references_from(resolved).freeze
        )
      end

      def references_to(target)
        artifact = resolve_argument(target)
        @references.select { _1.target.id == artifact.id }
      end

      def references_from(source)
        artifact = resolve_argument(source)
        @references.select { _1.source.id == artifact.id }
      end

      def callers_of(target)
        artifact = resolve_argument(target)
        references_to(artifact)
          .select { _1.relation == :calls }
          .map(&:source)
          .uniq(&:id)
      end

      def callees_of(source)
        artifact = resolve_argument(source)
        references_from(artifact)
          .select { _1.relation == :calls }
          .map(&:target)
          .uniq(&:id)
      end

      def impact_of(target, transitive: true)
        root = resolve_argument(target)
        seen = Set[root.id]
        queue = [root]
        affected = []
        traversed = []

        until queue.empty?
          current = queue.shift
          incoming = references_to(current)
          traversed.concat(incoming)
          incoming.each do |reference|
            source = reference.source
            next if seen.include?(source.id)

            seen << source.id
            affected << source
            queue << source if transitive
          end
        end

        Impact.new(root, affected.freeze, traversed.uniq.freeze)
      end

      private

      def ruby_semantic_hits(query, embedder, limit)
        Embedder.rank_with_distance(@artifacts, query, embedder:, limit:).map do |ranked|
          SemanticSearchHit.new(ranked.artifact, ranked.distance)
        end.freeze
      end

      # sqlite-vec returns Euclidean distance. Embeddings are normalized, so
      # d² / 2 is the equivalent cosine distance used by the Ruby fallback.
      def cosine_distance(euclidean) = (Float(euclidean)**2) / 2.0

      def build
        index_modules_and_domain_models
        index_units
        scan_documents
        @artifacts.freeze
        @references.freeze
        @unresolved_references.freeze
      end

      def index_modules_and_domain_models
        @project.modules.each do |mod|
          add_artifact(
            id: "module:#{mod.id}", qualified_name: mod.name, kind: :module,
            module_name: mod.name, name: mod.name, unit_id: mod.id,
            path: [], metadata: {}
          )

          entity_by_id = mod.entities.to_h { [_1.id, _1] }
          mod.entities.each do |entity|
            qualified = entity.qualified_name.to_s
            qualified = "#{mod.name}.#{entity.name}" if qualified.empty?
            artifact = add_artifact(
              id: "entity:#{entity.id}", qualified_name: qualified, kind: :entity,
              module_name: mod.name, name: entity.name, unit_id: mod.domain_model&.id,
              path: ["entities", entity.name], metadata: { model: entity }
            )
            entity.attributes.each do |attribute|
              add_artifact(
                id: "attribute:#{attribute.id}",
                qualified_name: "#{qualified}.#{attribute.name}", kind: :attribute,
                module_name: mod.name, name: attribute.name, unit_id: mod.domain_model&.id,
                path: artifact.path + ["attributes", attribute.name],
                metadata: { model: attribute, entity: artifact }
              )
            end
          end

          mod.associations.each do |association|
            from_entity = entity_by_id[association.from_entity_id]
            to_entity = entity_by_id[association.to_entity_id]
            add_artifact(
              id: "association:#{association.id}",
              qualified_name: "#{mod.name}.#{association.name}", kind: :association,
              module_name: mod.name, name: association.name, unit_id: mod.domain_model&.id,
              path: ["associations", association.name],
              metadata: {
                model: association,
                from: qualified_entity_name(mod, from_entity),
                to: qualified_entity_name(mod, to_entity)
              }
            )
          end

          domain_raw = mod.domain_model && @project.raw_unit(mod.domain_model.id)
          next unless domain_raw

          domain_doc = @project.parse_bson(domain_raw)
          domain_entities(domain_doc).each do |entity_doc|
            entity_id = Mxrb::IO::BsonCodec.extract_id(entity_doc["$ID"])
            source = @by_id["entity:#{entity_id}"]
            @documents << [source, entity_doc] if source
          end
          domain_associations(domain_doc).each do |association_doc|
            association_id = Mxrb::IO::BsonCodec.extract_id(association_doc["$ID"])
            source = @by_id["association:#{association_id}"]
            @documents << [source, association_doc] if source
          end
        end
      end

      def index_units
        units = @project.all_units
        units_by_id = units.to_h { [_1["UnitID"], _1] }
        module_by_id = @project.modules.to_h { [_1.id, _1.name] }

        units.each do |raw|
          doc = @project.parse_bson(raw)
          type = doc["$Type"].to_s
          next if type.empty? || %w[Projects$Module Projects$ModuleImpl].include?(type) ||
                  type.include?("DomainModel")

          name = doc["Name"] || doc["name"]
          name = "Navigation" if name.to_s.empty? && type == "Navigation$NavigationDocument"
          next if name.to_s.empty?

          module_name = ancestor_module(raw, units_by_id, module_by_id)
          qualified = if type == "Navigation$NavigationDocument"
                        "Project.Navigation"
                      elsif module_name
                        "#{module_name}.#{name}"
                      else
                        name.to_s
                      end
          artifact = add_artifact(
            id: "unit:#{raw['UnitID']}", qualified_name: qualified,
            kind: kind_for(type), module_name: module_name, name: name.to_s,
            unit_id: raw["UnitID"], path: [], metadata: {
              bson_type: type,
              documentation: (doc["Documentation"] || doc["documentation"]).to_s,
              allowed_roles: semantic_array(doc["AllowedModuleRoles"] || doc["AllowedRoles"]),
              excluded: doc["Excluded"] == true,
              mark_as_used: doc["MarkAsUsed"] == true,
              exposed: exposed_document?(doc)
            }.freeze
          )
          @documents << [artifact, doc]
        end
      end

      def scan_documents
        seen = Set.new
        unresolved_seen = Set.new
        @documents.each do |source, document|
          walk(document) do |path, value|
            next if metadata_path?(path)

            candidates_for(value, source).each do |candidate|
              target = resolve_candidate(candidate, source, path)
              unless target
                add_unresolved(
                  source, candidate, path, value, unresolved_seen
                )
                next
              end
              next if target.id == source.id && self_identity_path?(path)

              relation = relation_for(path, target)
              key = [source.id, target.id, relation, path]
              next if seen.include?(key)

              seen << key
              @references << Reference.new(
                source, target, relation, path.map(&:to_s).freeze, value
              )
            end
          end
        end
      end

      def add_unresolved(source, candidate, path, value, seen)
        kinds = expected_kinds(path.last)
        return if kinds.empty? || !semantic_name?(candidate)

        key = [source.id, candidate, kinds, path]
        return if seen.include?(key)

        seen << key
        @unresolved_references << UnresolvedReference.new(
          source, candidate, kinds.freeze, path.map(&:to_s).freeze, value
        )
      end

      def qualified_entity_name(mod, entity)
        return unless entity
        return entity.qualified_name unless entity.qualified_name.to_s.empty?

        "#{mod.name}.#{entity.name}"
      end

      def semantic_name?(candidate)
        candidate.match?(/\A[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*){1,2}\z/)
      end

      def add_artifact(**attributes)
        artifact = Artifact.new(**attributes)
        existing = @by_id[artifact.id]
        return existing if existing

        @artifacts << artifact
        @by_id[artifact.id] = artifact
        @by_name[artifact.qualified_name] << artifact
        artifact
      end

      def walk(value, path = [], &block)
        case value
        when Hash
          value.each { |key, child| walk(child, path + [key], &block) }
        when Array
          value.each_with_index { |child, index| walk(child, path + [index], &block) }
        when String
          yield(path, value)
        end
      end

      def candidates_for(value, source)
        direct = [value]
        direct << "#{source.module_name}.#{value}" if source.module_name && !value.include?(".")
        direct.concat(value.scan(TOKEN))
        direct.concat(value.scan(MEMBER_TOKEN).map { _1.tr("/", ".") })
        direct.uniq
      end

      def resolve_candidate(candidate, source, path)
        matches = @by_name[candidate]
        return matches.first if matches.one?
        return nil if matches.empty?

        expected = expected_kinds(path.last)
        narrowed = matches.select { expected.include?(_1.kind) }
        return narrowed.first if narrowed.one?

        local = matches.select { _1.module_name == source.module_name }
        local.one? ? local.first : nil
      end

      def resolve_argument(value)
        artifact = find(value)
        return artifact if artifact

        matches = find_all(value)
        if matches.empty?
          raise KeyError, "unknown Mendix artifact #{value.inspect}"
        end

        kinds = matches.map(&:kind).uniq.join(", ")
        raise ArgumentError, "ambiguous Mendix artifact #{value.inspect} (#{kinds})"
      end

      def relation_for(path, target)
        FIELD_RELATIONS.fetch(normalize_field(path.last)) do
          CALL_KINDS.include?(target.kind) ? :references : :"uses_#{target.kind}"
        end
      end

      def expected_kinds(field)
        case normalize_field(field)
        when "microflow" then [:microflow]
        when "nanoflow" then [:nanoflow]
        when "javaaction" then [:java_action]
        when "javascriptaction" then [:javascript_action]
        when "workflow" then [:workflow]
        when "form", "page" then %i[page layout snippet]
        when "layout" then [:layout]
        when "snippet" then [:snippet]
        when "entity" then [:entity]
        when "attribute" then [:attribute]
        when "association" then [:association]
        when "enumeration" then [:enumeration]
        else []
        end
      end

      def normalize_field(field)
        field.to_s.gsub(/[^A-Za-z]/, "").downcase
      end

      def metadata_path?(path)
        %w[$Type $ID ContentsHash Documentation Caption Text].include?(path.last.to_s)
      end

      def self_identity_path?(path)
        %w[$QualifiedName QualifiedName Name name].include?(path.last.to_s)
      end

      def ancestor_module(raw, units_by_id, module_by_id)
        current = raw
        visited = Set.new
        loop do
          container = current["ContainerID"]
          return module_by_id[container] if module_by_id.key?(container)
          return nil if container.nil? || visited.include?(container)

          visited << container
          current = units_by_id[container]
          return nil unless current
        end
      end

      def kind_for(type)
        suffix = type.split("$", 2).last.to_s
        {
          "Microflow" => :microflow,
          "Nanoflow" => :nanoflow,
          "Page" => :page,
          "Layout" => :layout,
          "Snippet" => :snippet,
          "Enumeration" => :enumeration,
          "Constant" => :constant,
          "ScheduledEvent" => :scheduled_event,
          "MenuDocument" => :menu,
          "JavaAction" => :java_action,
          "JavaScriptAction" => :javascript_action,
          "Workflow" => :workflow
        }.fetch(suffix) do
          suffix.gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase.to_sym
        end
      end

      def exposed_document?(doc)
        doc.any? do |key, value|
          key.to_s.match?(/\A(?:Expose|Exposed|Published)/) && value != false && !value.nil?
        end
      end

      def semantic_array(value)
        Mxrb::IO::BsonCodec.parse_array(value)[:items].map(&:to_s).freeze
      end

      def domain_entities(doc)
        Mxrb::IO::BsonCodec.parse_array(doc["entities"] || doc["Entities"])[:items]
      end

      def domain_associations(doc)
        local = doc["associations"] || doc["Associations"]
        cross = doc["crossAssociations"] || doc["CrossAssociations"]
        Mxrb::IO::BsonCodec.parse_array(local)[:items] +
          Mxrb::IO::BsonCodec.parse_array(cross)[:items]
      end

      # ── Index cache ──────────────────────────────────────────────────────────

      def reset_state
        @artifacts            = []
        @references           = []
        @unresolved_references = []
        @by_id                = {}
        @by_name              = Hash.new { |hash, key| hash[key] = [] }
        @documents            = []
        @vec_store = nil
        @semantic_embedders = {}
      end

      def semantic_embedder(backend)
        @semantic_embedders[backend] ||= Embedder.build(backend:)
      end

      def vec_store(embedder)
        return nil if @project.mpr.readonly? || !@fingerprint || !VecStore.available?
        return @vec_store if @vec_store&.backend == embedder.backend

        @vec_store = VecStore.new(@project.mpr, embedder:, fingerprint: @fingerprint)
      rescue SQLite3::Exception, LoadError
        nil
      end

      def compute_fingerprint
        self.class.fingerprint(@project)
      end

      def serialize_to_cache
        JSON.generate(
          version: CACHE_VERSION,
          artifacts: @artifacts.map { |a|
            { id: a.id, qualified_name: a.qualified_name, kind: a.kind.to_s,
              module_name: a.module_name, name: a.name, unit_id: a.unit_id, path: a.path,
              metadata: a.metadata.slice(*CACHE_METADATA_KEYS) }
          },
          references: @references.map { |r|
            { source_id: r.source.id, target_id: r.target.id,
              relation: r.relation.to_s, path: r.path, value: r.value }
          },
          unresolved: @unresolved_references.map { |u|
            { source_id: u.source.id, qualified_name: u.qualified_name,
              expected_kinds: u.expected_kinds.map(&:to_s), path: u.path, value: u.value }
          }
        )
      end

      def restore_from_cache(json)
        data = JSON.parse(json, symbolize_names: true)
        raise TypeError, "unsupported semantic index cache" unless data[:version] == CACHE_VERSION

        data.fetch(:artifacts).each do |a|
          artifact = Artifact.new(
            id: a.fetch(:id), qualified_name: a.fetch(:qualified_name),
            kind: a.fetch(:kind).to_sym,
            module_name: a[:module_name], name: a[:name], unit_id: a[:unit_id],
            path: Array(a[:path]), metadata: a.fetch(:metadata, {})
          )
          @artifacts << artifact
          @by_id[artifact.id] = artifact
          @by_name[artifact.qualified_name] << artifact
        end
        hydrate_cached_domain_metadata
        data.fetch(:references).each do |r|
          source = @by_id[r[:source_id]]
          target = @by_id[r[:target_id]]
          raise TypeError, "invalid cached reference" unless source && target

          @references << Reference.new(source, target, r[:relation].to_sym,
                                       Array(r[:path]), r[:value])
        end
        data.fetch(:unresolved).each do |u|
          source = @by_id[u[:source_id]]
          raise TypeError, "invalid cached unresolved reference" unless source

          @unresolved_references << UnresolvedReference.new(
            source, u[:qualified_name],
            u[:expected_kinds].map(&:to_sym).freeze,
            Array(u[:path]), u[:value]
          )
        end
        @artifacts.freeze
        @references.freeze
        @unresolved_references.freeze
        true
      rescue JSON::ParserError, KeyError, TypeError, NoMethodError
        false
      end

      def hydrate_cached_domain_metadata
        @project.modules.each do |mod|
          mod.entities.each do |entity|
            entity_artifact = @by_id.fetch("entity:#{entity.id}")
            entity_artifact.metadata[:model] = entity
            entity.attributes.each do |attribute|
              attribute_artifact = @by_id.fetch("attribute:#{attribute.id}")
              attribute_artifact.metadata[:model] = attribute
              attribute_artifact.metadata[:entity] = entity_artifact
            end
          end
          mod.associations.each do |association|
            artifact = @by_id.fetch("association:#{association.id}")
            artifact.metadata[:model] = association
          end
        end
      end
    end
  end
end
