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
        definition = definition.merge(security: native_security_definition(security)) \
          unless definition[:security]
        persistent_access_diagnostics(security) +
          secured_artifact_diagnostics(security) +
          public_contract_diagnostics(definition) +
          navigation_diagnostics(definition) +
          duplicate_role_diagnostics(definition) +
          design_system_diagnostics(definition)
      end

      def native_security_definition(security)
        roles = IO::BsonCodec.parse_array(security&.fetch("UserRoles", nil))[:items]
        {
          user_roles: roles.map do |role|
            {
              name: role["Name"],
              module_roles: IO::BsonCodec.parse_array(role["ModuleRoles"])[:items]
            }
          end
        }
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
        fallback = @project.navigation.to_h[:profiles] if @project.respond_to?(:navigation)
        profiles = Array(definition.dig(:navigation, :profiles) || fallback)
        duplicate_names = profiles.map { _1[:name].to_s }.tally
        diagnostics = profiles.filter_map do |profile|
          next unless duplicate_names.fetch(profile[:name].to_s) > 1

          duplicate_names[profile[:name].to_s] = 0
          Diagnostic.new(
            :duplicate_navigation_profile, :error,
            "duplicate navigation profile: #{profile[:name]}",
            [].freeze, { profile: profile[:name] }.freeze
          )
        end
        diagnostics + profiles.flat_map { profile_navigation_diagnostics(_1, definition) }
      end

      def profile_navigation_diagnostics(profile, definition)
        targets = navigation_targets(profile)
        missing = targets.filter_map do |field, target|
          next if target.to_s.empty? || @index.find(target)

          Diagnostic.new(
            :missing_navigation_target, :error,
            "navigation profile #{profile[:name]} references missing #{field}: #{target}",
            [].freeze, { profile: profile[:name], field:, target: }.freeze
          )
        end
        missing +
          navigation_home_diagnostics(profile) +
          navigation_role_diagnostics(profile, definition) +
          navigation_role_access_diagnostics(profile, definition)
      end

      def navigation_targets(profile)
        targets = profile.values_at(:home_page, :home_microflow, :sign_in_page, :menu)
                         .then { %i[home_page home_microflow sign_in_page menu].zip(_1).to_h }
        role_homes = profile.fetch(:role_homes, {})
        homes = role_homes.is_a?(Hash) ? role_homes.map { |role, page| { role:, page: } } : role_homes
        homes += Array(profile[:role_home_details])
        homes.each { targets["role_home:#{_1[:role]}"] = _1[:page] || _1[:microflow] }
        targets
      end

      def navigation_home_diagnostics(profile)
        return [] if profile[:home_page] || profile[:home_microflow]

        [Diagnostic.new(
          :navigation_profile_without_home, :error,
          "navigation profile has no default home: #{profile[:name]}",
          [].freeze, { profile: profile[:name] }.freeze
        )]
      end

      def navigation_role_diagnostics(profile, definition)
        known = Array(definition.dig(:security, :user_roles)).map { _1[:name].to_s }
        role_homes = profile.fetch(:role_homes, {})
        roles = if role_homes.is_a?(Hash)
                  role_homes.keys
                else
                  role_homes.map { _1[:role] }
                end
        roles += Array(profile[:role_home_details]).map { _1[:role] }
        roles.uniq.filter_map do |role|
          next if known.include?(role.to_s)

          Diagnostic.new(
            :unknown_navigation_role, :error,
            "navigation profile #{profile[:name]} uses unknown user role: #{role}",
            [].freeze, { profile: profile[:name], role: role.to_s }.freeze
          )
        end
      end

      def navigation_role_access_diagnostics(profile, definition)
        roles = Array(definition.dig(:security, :user_roles)).to_h do |role|
          [role[:name].to_s, Array(role[:module_roles]).map(&:to_s)]
        end
        navigation_role_homes(profile).filter_map do |home|
          target = @index.find(home[:page] || home[:microflow])
          allowed = target && Array(target.metadata[:allowed_roles])
          next if !target || allowed.empty? || !roles.key?(home[:role].to_s)

          qualified = allowed.map do |role|
            role.include?('.') ? role : "#{target.module_name}.#{role}"
          end
          next unless (qualified & roles.fetch(home[:role].to_s)).empty?

          Diagnostic.new(
            :inaccessible_navigation_home, :error,
            "user role #{home[:role]} cannot access navigation home #{target.qualified_name}",
            [target].freeze, { role: home[:role].to_s, target: target.qualified_name }.freeze
          )
        end
      end

      def navigation_role_homes(profile)
        homes = profile.fetch(:role_homes, {})
        homes = homes.map { |role, page| { role:, page: } } if homes.is_a?(Hash)
        homes + Array(profile[:role_home_details])
      end

      def design_system_diagnostics(definition)
        return [] unless @project.respond_to?(:design_system)

        diagnostics = @project.design_system.unresolved_references.map do |entry|
          token = entry.fetch(:token)
          Diagnostic.new(
            :unresolved_design_token, :error,
            "#{token.path}:#{token.line} references missing design token #{entry.fetch(:reference)}",
            [].freeze, entry.freeze
          )
        end
        diagnostics.concat(contrast_diagnostics(definition))
        return diagnostics unless definition.dig(:design_system, :forbid_literal_colors)

        diagnostics + @project.design_system.literal_colors.map do |token|
          Diagnostic.new(
            :literal_design_color, :warning,
            "#{token.path}:#{token.line} uses literal color #{token.value}",
            [].freeze, { token: token.name, value: token.value }.freeze
          )
        end
      end

      def contrast_diagnostics(definition)
        design = definition[:design_system] || {}
        tokens = Array(design[:tokens]) +
                 Array(design[:themes]).flat_map { Array(_1[:tokens]) }
        values = tokens.to_h { [_1[:name].to_s, _1[:value].to_s] }
        Array(design[:contrast_pairs]).filter_map do |pair|
          foreground = values.fetch(pair[:foreground].to_s, pair[:foreground].to_s)
          background = values.fetch(pair[:background].to_s, pair[:background].to_s)
          ratio = @project.design_system.contrast_ratio(foreground, background)
          required = pair[:level].to_s.downcase == "aaa" ? 7.0 : 4.5
          next if ratio >= required

          Diagnostic.new(
            :insufficient_color_contrast, :error,
            "color contrast #{ratio}:1 is below #{pair[:level].to_s.upcase} (#{required}:1)",
            [].freeze, pair.merge(ratio:, required:).freeze
          )
        rescue ArgumentError
          Diagnostic.new(
            :invalid_contrast_color, :error,
            "contrast pair uses a non-hex color: #{foreground} / #{background}",
            [].freeze, pair.freeze
          )
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
