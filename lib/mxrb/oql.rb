# frozen_string_literal: true

module Mxrb
  # Read-only discovery and SQL visualization for native OQL stored in an MPR.
  # Generated SQL is never executed by MXRB.
  module Oql
    Query = Data.define(
      :id, :qualified_name, :name, :kind, :oql, :unit_id, :path, :source_type, :parameters
    )

    SqlView = Data.define(
      :query, :sql, :dialect, :confidence, :warnings, :parameters
    ) do
      def supported? = !sql.nil?
    end

    Finding = Data.define(:rule, :severity, :fragment, :message, :suggestions)

    AnalysisReport = Data.define(:query, :findings) do
      def clean? = findings.none? { _1.severity == :error }
      def warnings? = findings.any? { _1.severity == :warning }

      def for_dialect(dialect)
        key = dialect.to_sym
        findings.map { [_1, _1.suggestions[key]] }.freeze
      end
    end

    # Finds OQL-bearing native model elements without treating arbitrary strings as queries.
    class Catalog
      def initialize(project)
        @project = project
      end

      def queries
        @queries ||= begin
          units = @project.all_units
          units_by_id = units.to_h { [_1['UnitID'], _1] }
          module_by_id = @project.modules.to_h { [_1.id, _1.name] }
          units.flat_map do |raw|
            document = @project.parse_bson(raw)
            module_name = ancestor_module(raw, units_by_id, module_by_id)
            discover(document, raw, module_name)
          end.sort_by(&:qualified_name).freeze
        end
      end

      private

      # Recursive BSON discovery is intentionally kept together so that its
      # source-type guard and ownership context cannot diverge.
      # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      def discover(document, raw, module_name)
        found = []
        walk(document) do |node, path, ancestors|
          source_type = node['$Type'].to_s
          if source_type.match?(/Oql/i) && node['Query'].is_a?(String)
            found << build_query(
              node['Query'], raw, module_name, path + ['Query'], source_type, ancestors
            )
          end
          node.each do |key, value|
            next unless key.to_s.match?(/\AOqlQuery\z/i) && value.is_a?(String)

            found << build_query(value, raw, module_name, path + [key], source_type, ancestors)
          end
        end
        found.uniq { [_1.unit_id, _1.path] }
      end
      # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

      # rubocop:disable Metrics/CyclomaticComplexity, Metrics/MethodLength
      def walk(node, path = [], ancestors = [], &block)
        return unless node.is_a?(Hash)

        named = node['Name'] || node['name']
        current_ancestors = named ? ancestors + [node] : ancestors
        yield(node, path, current_ancestors)
        node.each do |key, value|
          case value
          when Hash
            walk(value, path + [key], current_ancestors, &block)
          when Array
            value.each_with_index do |child, index|
              walk(child, path + [key, index], current_ancestors, &block)
            end
          end
        end
      end
      # rubocop:enable Metrics/CyclomaticComplexity, Metrics/MethodLength

      # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity
      # rubocop:disable Metrics/MethodLength, Metrics/ParameterLists, Metrics/PerceivedComplexity
      def build_query(oql, raw, module_name, path, source_type, ancestors)
        owner = ancestors.last || {}
        name = (owner['Name'] || owner['name'] || "OQL_#{raw['UnitID'].delete('-')[0, 8]}").to_s
        unit_type = @project.parse_bson(raw)['$Type'].to_s
        kind = if unit_type == 'DataSets$DataSet'
                 :dataset
               elsif owner['$Type'].to_s.match?(/Entity/i)
                 :view_entity
               else
                 :oql
               end
        id = Mxrb::IO::BsonCodec.extract_id(owner['$ID']) || raw['UnitID']
        qualified_name = module_name ? "#{module_name}.#{name}" : name
        parameters = Translator.parameters(oql)
        Query.new(
          id, qualified_name, name, kind, oql.freeze, raw['UnitID'],
          path.map(&:to_s).freeze, source_type, parameters
        )
      end
      # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity
      # rubocop:enable Metrics/MethodLength, Metrics/ParameterLists, Metrics/PerceivedComplexity

      def ancestor_module(raw, units_by_id, module_by_id)
        current = raw
        visited = {}
        loop do
          container = current['ContainerID']
          return module_by_id[container] if module_by_id.key?(container)
          return nil if container.nil? || visited[container]

          visited[container] = true
          current = units_by_id[container]
          return nil unless current
        end
      end
    end

    # Converts the deliberately small, safe OQL read subset into inspectable SQL.
    # rubocop:disable Metrics/ClassLength
    class Translator
      DIALECTS = %i[ansi postgresql sql_server].freeze
      Token = Data.define(:type, :text)
      SPACE = /\s/
      WORD_START = /[A-Za-z_]/
      WORD_BODY = /[A-Za-z0-9_$]/
      TAIL_CLAUSES = %w[ORDER LIMIT OFFSET UNION].freeze
      ALIAS_STOP_WORDS = %w[
        FULL GROUP HAVING INNER JOIN LEFT LIMIT OFFSET ON ORDER OUTER RIGHT
        SELECT UNION WHERE
      ].freeze

      def initialize(dialect: :postgresql)
        @dialect = dialect.to_sym
        raise ArgumentError, "unsupported SQL dialect #{@dialect.inspect}" unless DIALECTS.include?(@dialect)
      end

      def self.parameters(source)
        new.send(:tokenize, source).filter_map do |token|
          token.text.delete_prefix('$') if token.type == :parameter
        end.uniq.freeze
      end

      def translate_source(source, name: 'AdHoc')
        text = source.to_s
        query = Query.new(
          'adhoc', name, name, :oql, text.freeze, nil, [].freeze,
          'Oql$AdHoc', self.class.parameters(text)
        )
        translate(query)
      end

      # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      def translate(query)
        tokens = tokenize(query.oql)
        warning = validation_warning(tokens)
        return unsupported(query, warning) if warning

        tokens = reorder_from_first(tokens)
        association = association_path(tokens)
        return unsupported(query, association) if association

        aliases = translate_entities!(tokens)
        translate_attributes!(tokens, aliases)
        translate_parameters!(tokens)
        sql = tokens.map(&:text).join.strip
        SqlView.new(
          query, sql.freeze, @dialect, :logical,
          [physical_mapping_warning].freeze, query.parameters
        )
      end
      # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

      private

      def tokenize(source)
        tokens = []
        index = 0
        while index < source.length
          type, text, index = next_token(source, index)
          tokens << Token.new(type, text)
        end
        tokens
      end

      # Lexical branching is explicit to keep strings and comments opaque.
      # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      def next_token(source, index)
        char = source[index]
        return consume_while(source, index, :space) { SPACE.match?(_1) } if SPACE.match?(char)
        return consume_quoted(source, index, "'", :string) if char == "'"
        return consume_quoted(source, index, '"', :quoted_identifier) if char == '"'
        return consume_line_comment(source, index) if source[index, 2] == '--'
        return consume_block_comment(source, index) if source[index, 2] == '/*'
        return consume_parameter(source, index) if char == '$' && source[index + 1]&.match?(WORD_START)
        return consume_while(source, index, :word) { WORD_BODY.match?(_1) } if WORD_START.match?(char)

        [:symbol, char, index + 1]
      end
      # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

      def consume_while(source, index, type)
        finish = index
        finish += 1 while finish < source.length && yield(source[finish])
        [type, source[index...finish], finish]
      end

      # rubocop:disable Metrics/MethodLength
      def consume_quoted(source, index, delimiter, type)
        finish = index + 1
        while finish < source.length
          if source[finish] == delimiter
            finish += 1
            if source[finish] == delimiter
              finish += 1
              next
            end
            break
          end
          finish += 1
        end
        [type, source[index...finish], finish]
      end
      # rubocop:enable Metrics/MethodLength

      def consume_line_comment(source, index)
        finish = source.index("\n", index) || source.length
        [:comment, source[index...finish], finish]
      end

      def consume_block_comment(source, index)
        finish = source.index('*/', index + 2)
        finish = finish ? finish + 2 : source.length
        [:comment, source[index...finish], finish]
      end

      def consume_parameter(source, index)
        _type, text, finish = consume_while(source, index + 1, :word) { WORD_BODY.match?(_1) }
        [:parameter, "$#{text}", finish]
      end

      def validation_warning(tokens)
        significant = tokens.reject { %i[space comment].include?(_1.type) }
        first = significant.first&.text.to_s.upcase
        return 'only read-only OQL SELECT queries can be visualized' unless %w[SELECT FROM].include?(first)
        return 'multiple OQL statements are not accepted' if significant.any? { _1.text == ';' }

        nil
      end

      # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      def reorder_from_first(tokens)
        first = significant_indices(tokens).first
        return tokens unless tokens[first].text.casecmp?('FROM')

        select_index = top_level_keyword(tokens, 'SELECT')
        return tokens unless select_index

        tail_index = TAIL_CLAUSES.filter_map do |keyword|
          top_level_keyword(tokens, keyword, after: select_index + 1)
        end.min || tokens.length
        select_part = tokens[select_index...tail_index]
        from_part = tokens[0...select_index]
        tail_part = tokens[tail_index..]
        select_part + [Token.new(:space, "\n")] + from_part + tail_part
      end
      # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

      def significant_indices(tokens)
        tokens.each_index.reject { %i[space comment].include?(tokens[_1].type) }
      end

      # rubocop:disable Metrics/CyclomaticComplexity
      def top_level_keyword(tokens, keyword, after: 0)
        depth = 0
        tokens.each_index do |index|
          token = tokens[index]
          depth += 1 if token.text == '('
          depth -= 1 if token.text == ')'
          next if index < after || depth != 0 || token.type != :word
          return index if token.text.casecmp?(keyword)
        end
        nil
      end
      # rubocop:enable Metrics/CyclomaticComplexity

      # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity
      def association_path(tokens)
        significant_indices(tokens).each do |index|
          next unless tokens[index].type == :word && tokens[index].text.match?(/\A(?:FROM|JOIN)\z/i)

          following = next_significant(tokens, index)
          next if following.nil? || tokens[following].text == '('

          separator = next_significant(tokens, following)
          if separator && tokens[separator].text == '/'
            return 'association-path JOINs require Mendix Runtime storage metadata'
          end
        end
        nil
      end
      # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity

      # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity
      # rubocop:disable Metrics/MethodLength, Metrics/PerceivedComplexity
      def translate_entities!(tokens)
        aliases = {}
        significant_indices(tokens).each do |index|
          next unless tokens[index].type == :word && tokens[index].text.match?(/\A(?:FROM|JOIN)\z/i)

          first = next_significant(tokens, index)
          next if first.nil? || tokens[first].text == '('

          dot = next_significant(tokens, first)
          entity = dot && next_significant(tokens, dot)
          next unless entity && tokens[dot].text == '.' && identifier?(tokens[first]) &&
                      identifier?(tokens[entity])

          module_name = identifier_text(tokens[first])
          entity_name = identifier_text(tokens[entity])
          tokens[first] = Token.new(:quoted_identifier, quote_table(module_name, entity_name))
          tokens[dot] = Token.new(:symbol, '')
          tokens[entity] = Token.new(:word, '')
          alias_index = next_significant(tokens, entity)
          alias_index = next_significant(tokens, alias_index) \
            if alias_index && tokens[alias_index].text.casecmp?('AS')
          alias_name = if alias_index && identifier?(tokens[alias_index]) &&
                          !ALIAS_STOP_WORDS.include?(tokens[alias_index].text.upcase)
                         identifier_text(tokens[alias_index])
                       else
                         entity_name
                       end
          aliases[alias_name.downcase] = true
        end
        aliases
      end
      # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity
      # rubocop:enable Metrics/MethodLength, Metrics/PerceivedComplexity

      # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength
      def translate_attributes!(tokens, aliases)
        significant_indices(tokens).each do |index|
          token = tokens[index]
          next unless identifier?(token) && aliases[identifier_text(token).downcase]

          separator = next_significant(tokens, index)
          attribute = separator && next_significant(tokens, separator)
          next unless attribute && %w[. /].include?(tokens[separator].text) &&
                      identifier?(tokens[attribute])

          tokens[separator] = Token.new(:symbol, '.')
          tokens[attribute] = Token.new(
            :quoted_identifier, quote_attribute(identifier_text(tokens[attribute]))
          )
        end
      end
      # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength

      def translate_parameters!(tokens)
        tokens.map! do |token|
          token.type == :parameter ? Token.new(:parameter, ":#{token.text.delete_prefix('$')}") : token
        end
      end

      def identifier?(token)
        %i[word quoted_identifier].include?(token.type)
      end

      def identifier_text(token)
        return token.text unless token.type == :quoted_identifier

        token.text[1...-1].gsub('""', '"')
      end

      def next_significant(tokens, index)
        ((index + 1)...tokens.length).find do |candidate|
          !%i[space comment].include?(tokens[candidate].type)
        end
      end

      def quote_table(module_name, entity_name)
        logical = if @dialect == :ansi
                    "#{module_name}.#{entity_name}"
                  else
                    "#{module_name.downcase}$#{entity_name.downcase}"
                  end
        quote_identifier(logical)
      end

      def quote_identifier(value)
        return "[#{value.gsub(']', ']]')}]" if @dialect == :sql_server

        %("#{value.gsub('"', '""')}")
      end

      def quote_attribute(value)
        quote_identifier(@dialect == :ansi ? value : value.downcase)
      end

      def physical_mapping_warning
        'logical table and column names are inferred; verify them against the Runtime database schema'
      end

      def unsupported(query, warning)
        SqlView.new(query, nil, @dialect, :unsupported, [warning].freeze, query.parameters)
      end
    end
    # rubocop:enable Metrics/ClassLength
  end
end

require_relative 'oql/analyzer'
