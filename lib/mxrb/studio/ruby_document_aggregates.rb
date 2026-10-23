# frozen_string_literal: true

module Mxrb
  module Studio
    # A native aggregate may be represented by several real Ruby source files.
    # Verify declarations and loader references instead of guessing filenames.
    module RubyDocumentAggregates # rubocop:disable Metrics/ModuleLength
      private

      def aggregate_candidates
        case @document[:type]
        when 'DomainModels$DomainModel' then domain_candidates
        when 'Security$ModuleSecurity' then module_security_candidates
        when 'Projects$Module', 'Projects$ModuleImpl' then module_candidates
        when 'Projects$Project' then project_candidates
        end
      end

      def aggregate_result(matches)
        if matches == :ambiguous
          return unavailable('ambiguous_source', 'Multiple Ruby declarations claim the same native element.')
        end
        if matches.empty?
          return unavailable('source_not_found', 'No matching Ruby declaration was found in the linked project.')
        end

        files = matches.uniq { _1.fetch(:path) }
        return result(state: 'ready', **files.first) if files.one?

        result(state: 'choose', files:)
      end

      def domain_candidates
        entities = IO::BsonCodec.parse_array(@native_contents['entities'] || @native_contents['Entities'])[:items]
        matches = member_candidates(entities, :entity)
        return matches if matches == :ambiguous

        index = loaded_source('domain', 'model.rb')
        if index && source_nodes(index).all? { evaluation_path(_1, index) } &&
           (!source_nodes(index).empty? || empty_source?(index))
          matches.unshift(path: index, line: 1, label: "#{@document[:module]} — Domain model")
        end
        matches
      end

      def module_security_candidates
        roles = IO::BsonCodec.parse_array(@native_contents['ModuleRoles'])[:items]
        matches = member_candidates(roles, :module_role)
        return matches unless matches.empty? && roles.empty?

        path = loaded_source('security', 'security.rb')
        path && empty_source?(path) ? [{ path:, line: 1, label: "#{@document[:module]} — Security" }] : []
      end

      def member_candidates(members, declaration) # rubocop:disable Metrics/MethodLength
        matches = members.map do |member|
          name = member['Name']
          id = IO::BsonCodec.extract_id(member['$ID'])
          found = @source_paths.flat_map do |path|
            source_nodes(path).filter_map do |node|
              next unless member_declaration?(node, declaration, name, id)

              { path:, line: node.location.start_line, label: "#{@document[:module]}.#{name}" }
            end
          end
          return :ambiguous if found.size > 1

          found.first
        end
        matches.compact
      end

      def member_declaration?(node, declaration, name, id)
        return false unless bare_call?(node, declaration) && literal_argument(node) == name

        options = keyword_options(node)
        !options.key?('id') || literal(options['id'])&.downcase == id&.downcase
      end

      def module_candidates
        found = @source_paths.flat_map do |path|
          source_nodes(path).filter_map do |node|
            { path:, line: node.location.start_line, label: @document[:module] } if module_declaration?(node)
          end
        end
        found.size > 1 ? :ambiguous : found
      end

      def module_declaration?(node)
        node.is_a?(Prism::CallNode) && node.name == :module &&
          (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)) &&
          literal(node.arguments&.arguments&.first) == @document[:module]
      end

      def loaded_source(*segments)
        loader = "modules/#{@document[:module]}/module.rb"
        return unless @source_paths.include?(loader)

        declarations = source_nodes(loader).select { module_declaration?(_1) }
        return unless declarations.one?

        expected = "modules/#{@document[:module]}/#{segments.join('/')}"
        return unless @source_paths.include?(expected)

        expected if block_statements(declarations.first).any? { evaluation_path(_1, loader) == expected }
      end

      def evaluation_path(node, loader) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
        return unless bare_call?(node, :evaluate)

        join = node.arguments&.arguments&.first
        return unless namespace_call?(join, :File, :join)

        arguments = join.arguments&.arguments || []
        return unless bare_call?(arguments.first, :__dir__)

        parts = arguments.drop(1).map { literal(_1) }
        return if parts.empty? || !parts.all? { safe_segment?(_1) }

        File.join(File.dirname(loader), *parts)
      end

      def safe_segment?(value)
        value && !value.empty? && !value.include?('/') && !%w[. ..].include?(value)
      end

      def bare_call?(node, name)
        node.is_a?(Prism::CallNode) && node.receiver.nil? && node.name == name
      end

      def namespace_call?(node, receiver, name)
        node.is_a?(Prism::CallNode) && node.name == name &&
          node.receiver.is_a?(Prism::ConstantReadNode) && node.receiver.name == receiver
      end

      def block_statements(node)
        block = node.block
        return [] unless block.is_a?(Prism::BlockNode) && block.body.is_a?(Prism::StatementsNode)

        block.body.body
      end

      def literal_argument(node) = literal(node.arguments&.arguments&.first)

      def empty_source?(path)
        parsed = Prism.parse(@files.read(path).fetch(:text))
        parsed.success? && Array(parsed.value.statements&.body).empty?
      rescue Errno::ENOENT, Errno::ENOTDIR
        false
      end

      def project_candidates
        source_nodes('project.rb').filter_map do |node|
          next unless namespace_call?(node, :Mxrb, :define)

          identity = block_statements(node).find do |child|
            bare_call?(child, :mendix_project_id) && literal_argument(child)&.downcase == @document[:unit_id].downcase
          end
          { path: 'project.rb', line: identity.location.start_line, label: 'Project' } if identity
        end
      end
    end
  end
end
