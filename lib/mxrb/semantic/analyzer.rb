# frozen_string_literal: true

module Mxrb
  module Semantic
    Diagnostic = Data.define(:rule, :severity, :message, :artifacts, :metadata)
    CallCycle = Data.define(:artifacts, :references)
    ModuleDependency = Data.define(:from, :to, :references, :source_artifacts)

    Report = Data.define(
      :diagnostics, :unreferenced, :unresolved_references, :call_cycles,
      :module_dependencies
    ) do
      def errors = diagnostics.select { _1.severity == :error }
      def warnings = diagnostics.select { _1.severity == :warning }
      def valid? = errors.empty?
    end

    # Static analysis for an opened Mendix project. The result is plain,
    # immutable Ruby data and can be filtered or extended without a query DSL.
    class Analyzer
      DEFAULT_UNREFERENCED_KINDS = %i[microflow nanoflow workflow page].freeze

      def initialize(project)
        @project = project
        @index = project.semantic_index
      end

      def analyze(unreferenced_kinds: DEFAULT_UNREFERENCED_KINDS, rules: [])
        cycles = call_cycles
        unreferenced = unreferenced_artifacts(unreferenced_kinds)
        unresolved = unresolved_references
        diagnostics = cycle_diagnostics(cycles) +
                      unresolved_diagnostics(unresolved) +
                      unreferenced_diagnostics(unreferenced) +
                      quality_diagnostics +
                      custom_diagnostics(rules)
        Report.new(
          diagnostics.sort_by { [_1.severity == :error ? 0 : 1, _1.message] }.freeze,
          unreferenced.freeze,
          unresolved.freeze,
          cycles.freeze,
          module_dependencies.freeze
        )
      end

      private

      def unreferenced_artifacts(kinds)
        selected_kinds = kinds.map(&:to_sym)
        incoming = @index.references.each_with_object(Set.new) { |ref, ids| ids << ref.target.id }
        @index.artifacts.select do |artifact|
          selected_kinds.include?(artifact.kind) &&
            !incoming.include?(artifact.id) &&
            !entry_point?(artifact)
        end.sort_by(&:qualified_name)
      end

      def entry_point?(artifact)
        artifact.metadata[:excluded] == true ||
          artifact.metadata[:mark_as_used] == true ||
          artifact.metadata[:exposed] == true
      end

      def unresolved_references
        return [] unless @index.respond_to?(:unresolved_references)

        @index.unresolved_references.reject do |reference|
          platform_reference?(reference) || reference.source.metadata[:excluded] == true
        end.sort_by do |reference|
          [reference.source.qualified_name, reference.path, reference.qualified_name]
        end
      end

      def platform_reference?(reference)
        reference.qualified_name.start_with?("System.")
      end

      def call_cycles
        call_references = @index.references.select { _1.relation == :calls }
        adjacency = Hash.new { |hash, key| hash[key] = [] }
        artifacts = {}
        call_references.each do |reference|
          adjacency[reference.source.id] << reference.target.id
          artifacts[reference.source.id] = reference.source
          artifacts[reference.target.id] = reference.target
        end

        strongly_connected(adjacency, artifacts.keys).filter_map do |ids|
          cyclic = ids.length > 1 || adjacency[ids.first].include?(ids.first)
          next unless cyclic

          id_set = ids.to_set
          references = call_references.select do |reference|
            id_set.include?(reference.source.id) && id_set.include?(reference.target.id)
          end
          CallCycle.new(
            ids.map { artifacts.fetch(_1) }.sort_by(&:qualified_name).freeze,
            references.freeze
          )
        end.sort_by { _1.artifacts.map(&:qualified_name) }
      end

      def strongly_connected(adjacency, nodes)
        index = 0
        indexes = {}
        low_links = {}
        stack = []
        on_stack = Set.new
        components = []

        visit = lambda do |node|
          indexes[node] = index
          low_links[node] = index
          index += 1
          stack << node
          on_stack << node

          adjacency[node].each do |target|
            unless indexes.key?(target)
              visit.call(target)
              low_links[node] = [low_links[node], low_links[target]].min
              next
            end
            low_links[node] = [low_links[node], indexes[target]].min if on_stack.include?(target)
          end

          return unless low_links[node] == indexes[node]

          component = []
          loop do
            member = stack.pop
            on_stack.delete(member)
            component << member
            break if member == node
          end
          components << component
        end

        nodes.each { visit.call(_1) unless indexes.key?(_1) }
        components
      end

      def module_dependencies
        grouped = @index.references.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |ref, groups|
          from = ref.source.module_name
          to = ref.target.module_name
          groups[[from, to]] << ref if from && to && from != to
        end

        grouped.map do |(from, to), references|
          ModuleDependency.new(
            from, to, references.freeze,
            references.map(&:source).uniq(&:id).sort_by(&:qualified_name).freeze
          )
        end.sort_by { [_1.from, _1.to] }
      end

      def cycle_diagnostics(cycles)
        cycles.map do |cycle|
          names = cycle.artifacts.map(&:qualified_name)
          Diagnostic.new(
            :call_cycle, :error,
            "call cycle: #{names.join(' -> ')} -> #{names.first}",
            cycle.artifacts, { references: cycle.references.size }.freeze
          )
        end
      end

      def unreferenced_diagnostics(artifacts)
        artifacts.map do |artifact|
          Diagnostic.new(
            :unreferenced, :warning,
            "unreferenced #{artifact.kind}: #{artifact.qualified_name}",
            [artifact].freeze, {}.freeze
          )
        end
      end

      def unresolved_diagnostics(references)
        references.map do |reference|
          external = external_reference?(reference)
          Diagnostic.new(
            external ? :external_reference : :unresolved_reference,
            external ? :warning : :error,
            "#{reference.source.qualified_name} references #{external ? 'external' : 'missing'} " \
            "#{reference.qualified_name} at #{reference.path.join('.')}",
            [reference.source].freeze,
            {
              target: reference.qualified_name,
              expected_kinds: reference.expected_kinds,
              path: reference.path
            }.freeze
          )
        end
      end

      def external_reference?(reference)
        target_module = reference.qualified_name.split(".").first
        @index.artifacts.none? { _1.module_name == target_module }
      end

      def quality_diagnostics
        security = project_security
        definition = if @project.respond_to?(:architecture_definition)
                       @project.architecture_definition || {}
                     else
                       {}
                     end
        persistent_access_diagnostics(security) +
          secured_artifact_diagnostics(security) +
          public_contract_diagnostics(definition) +
          navigation_diagnostics(definition) +
          duplicate_role_diagnostics(definition)
      end

      def project_security
        return nil unless @project.respond_to?(:all_units) && @project.respond_to?(:parse_bson)

        raw = @project.all_units.find do |unit|
          @project.parse_bson(unit)["$Type"] == "Security$ProjectSecurity"
        end
        raw && @project.parse_bson(raw)
      end

      def strict_security?(security)
        security && security["SecurityLevel"] == "CheckEverything"
      end

      def persistent_access_diagnostics(security)
        return [] unless strict_security?(security)

        @index.artifacts.filter_map do |artifact|
          next unless artifact.kind == :entity

          entity = artifact.metadata[:model]
          next unless entity
          next unless entity.persistable != false && Array(entity.access_rules).empty?

          Diagnostic.new(
            :persistent_entity_without_access, :warning,
            "persistent entity has no access rules: #{artifact.qualified_name}",
            [artifact].freeze, {}.freeze
          )
        end
      end

      def secured_artifact_diagnostics(security)
        return [] unless strict_security?(security)

        @index.artifacts.filter_map do |artifact|
          next unless %i[page microflow nanoflow].include?(artifact.kind)
          next if artifact.metadata[:excluded] == true
          next unless Array(artifact.metadata[:allowed_roles]).empty?

          Diagnostic.new(
            :secured_artifact_without_roles, :warning,
            "secured #{artifact.kind} has no allowed module roles: #{artifact.qualified_name}",
            [artifact].freeze, {}.freeze
          )
        end
      end

      def public_contract_diagnostics(definition)
        Array(definition[:modules]).flat_map do |mod|
          %i[microflows nanoflows repositories].flat_map do |collection|
            Array(mod[collection]).filter_map do |item|
              next unless item[:public] == true
              next unless item[:documentation].to_s.empty?

              artifact = @index.find("#{mod[:name]}.#{item[:name]}")
              Diagnostic.new(
                :public_contract_without_documentation, :warning,
                "public contract has no documentation: #{mod[:name]}.#{item[:name]}",
                Array(artifact).freeze, { kind: collection.to_s.sub(/s\z/, "").to_sym }.freeze
              )
            end
          end
        end
      end

      def navigation_diagnostics(definition)
        profiles = Array(definition.dig(:navigation, :profiles))
        profiles.flat_map do |profile|
          targets = {
            home_page: profile[:home_page],
            sign_in_page: profile[:sign_in_page],
            menu: profile[:menu]
          }
          targets.merge!(profile.fetch(:role_homes, {}).transform_keys { "role_home:#{_1}" })
          targets.filter_map do |field, target|
            next if target.to_s.empty? || @index.find(target)

            Diagnostic.new(
              :missing_navigation_target, :error,
              "navigation profile #{profile[:name]} references missing #{field}: #{target}",
              [].freeze, { profile: profile[:name], field:, target: }.freeze
            )
          end
        end
      end

      def duplicate_role_diagnostics(definition)
        roles = Array(definition.dig(:security, :user_roles))
        roles.filter_map do |role|
          module_roles = Array(role[:module_roles])
          duplicates = module_roles.tally.select { |_name, count| count > 1 }.keys.sort
          next if duplicates.empty?

          Diagnostic.new(
            :duplicate_module_role, :warning,
            "user role #{role[:name]} maps duplicate module roles: #{duplicates.join(', ')}",
            [].freeze, { user_role: role[:name], module_roles: duplicates.freeze }.freeze
          )
        end
      end

      def custom_diagnostics(rules)
        rules.flat_map do |rule|
          diagnostics = Array(rule.call(@project, @index))
          unless diagnostics.all? { _1.is_a?(Diagnostic) }
            raise ArgumentError, "custom semantic rules must return Mxrb::Semantic::Diagnostic"
          end
          diagnostics
        end
      end
    end
  end
end
