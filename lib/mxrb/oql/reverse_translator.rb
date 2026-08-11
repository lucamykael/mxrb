# frozen_string_literal: true

module Mxrb
  module Oql
    OqlProjection = Data.define(
      :sql, :oql, :dialect, :confidence, :warnings, :parameters
    ) do
      def supported? = !oql.nil?
    end

    # Converts a conservative, read-only SQL subset back into logical OQL.
    # Physical Runtime names are accepted as Module$Entity. Supplying a
    # project restores canonical entity and attribute casing.
    # Parser transformations are intentionally kept together so table, alias,
    # attribute and parameter state cannot diverge.
    # rubocop:disable Metrics
    class ReverseTranslator
      DIALECTS = Translator::DIALECTS
      STOP_CLAUSES = %w[GROUP HAVING LIMIT OFFSET ORDER UNION WHERE].freeze
      ALIAS_STOP_WORDS = (Translator::ALIAS_STOP_WORDS + %w[CROSS FETCH FOR]).freeze
      REJECTED_WORDS = %w[
        ALTER APPLY CALL COLLATE CREATE CROSS DELETE DROP EXEC EXECUTE FETCH
        FILTER FOR GRANT INSERT INTO LATERAL MERGE NATURAL NULLS OVER QUALIFY
        RETURNING REVOKE ROWS TOP TRUNCATE UNNEST UPDATE UPSERT VALUES
        WINDOW WITH
      ].freeze
      FUNCTIONS = %w[
        AVG CAST COALESCE COUNT DATEADD DATEDIFF DATEFORMAT DATEPARSE DATEPART
        DATETRUNC LENGTH LOCATE LOWER LPAD LTRIM MAX MIN RANGEBEGIN RANGEEND
        REPLACE ROUND RPAD RTRIM STRING_AGG SUBSTRING SUM TRIM UPPER
      ].freeze
      FUNCTION_ALIASES = { 'CHAR_LENGTH' => 'LENGTH', 'LEN' => 'LENGTH' }.freeze
      FUNCTION_LIKE_OPERATORS = %w[
        AS BOOLEAN CASE DATETIME DECIMAL EXISTS FLOAT FROM HAVING IN INTEGER
        JOIN LONG ON SELECT STRING WHEN WHERE
      ].freeze
      RESERVED = %w[
        ALL AND AS ASC AVG BOOLEAN BY CASE CAST COUNT DATETIME DAY DECIMAL
        DESC DISTINCT ELSE END EXISTS FALSE FLOAT FROM FULL GROUP HAVING HOUR
        IN INNER INTEGER IS JOIN KEY LEFT LIKE LIMIT LONG MATCHED MAX MERGE
        MILLISECOND MIN MINUTE MONTH NOT NULL OFFSET ON OR ORDER OUTER QUARTER
        REPLACE RIGHT SECOND SELECT SET SOURCE STRING STRING_AGG SUM TARGET
        THEN TRUE UNION UPDATE UPSERT USING VALUES WEEK WEEKDAY WHEN WHERE WITH
        YEAR
      ].freeze
      SCHEMAS = %w[dbo public].freeze

      def initialize(dialect: :postgresql, project: nil)
        @dialect = dialect.to_sym
        raise ArgumentError, "unsupported SQL dialect #{@dialect.inspect}" unless DIALECTS.include?(@dialect)

        @catalog = entity_catalog(project)
      end

      def translate(source)
        sql = source.to_s
        tokens = Translator.tokens(sql)
        translate_function_aliases!(tokens)
        warning = validation_warning(tokens)
        return unsupported(sql, warning) if warning

        warnings = []
        aliases = translate_tables!(tokens, warnings)
        return unsupported(sql, aliases) if aliases.is_a?(String)

        translate_attributes!(tokens, aliases)
        parameter_result = translate_parameters!(tokens)
        return unsupported(sql, parameter_result) if parameter_result.is_a?(String)

        translate_operators!(tokens)

        oql = tokens.map(&:text).join.strip
        confidence = warnings.empty? ? :logical : :inferred
        OqlProjection.new(
          sql.freeze, oql.freeze, @dialect, confidence,
          warnings.uniq.freeze, parameter_result.freeze
        )
      end

      private

      def validation_warning(tokens)
        significant = significant_indices(tokens)
        first = significant.first && tokens[significant.first].text.upcase
        return 'SQL keyword WITH has no safe OQL conversion' if first == 'WITH'
        return 'only read-only SQL SELECT queries can be converted to OQL' unless first == 'SELECT'
        return 'multiple SQL statements are not accepted' if significant.any? { tokens[_1].text == ';' }

        rejected = significant.find do |index|
          token = tokens[index]
          token.type == :word && REJECTED_WORDS.include?(token.text.upcase)
        end
        return "SQL keyword #{tokens[rejected].text.upcase} has no safe OQL conversion" if rejected
        return 'PostgreSQL casts using :: are not supported; use CAST(expression AS type)' \
          if adjacent_symbols?(tokens, ':', ':')
        return 'SQL ILIKE has no database-independent OQL equivalent' if keyword?(tokens, 'ILIKE')
        return 'PostgreSQL DISTINCT ON has no OQL equivalent' if adjacent_words?(tokens, 'DISTINCT', 'ON')
        return 'SQL table subqueries are outside the safe OQL conversion subset' if table_subquery?(tokens)

        function = unsupported_function(tokens)
        return "SQL function #{function} has no supported OQL equivalent" if function
        return 'SQL concatenation and bitwise operators have no safe OQL conversion' \
          if unsupported_operator?(tokens)
        return 'positional SQL parameters are not supported; use named parameters' \
          if significant.any? { tokens[_1].text == '?' } || postgres_positional_parameter?(tokens)

        nil
      end

      def translate_tables!(tokens, warnings)
        aliases = {}
        table_start_indices(tokens).each do |start|
          parsed = parse_table(tokens, start)
          return "SQL table #{tokens[start].text.inspect} cannot be mapped to Module.Entity" unless parsed

          info, finish, original, table_warnings = parsed
          warnings.concat(table_warnings)
          tokens[start] = Translator::Token.new(:word, render_qualified(info.fetch(:qualified_name)))
          ((start + 1)..finish).each { tokens[_1] = Translator::Token.new(:word, '') }

          alias_index = next_significant(tokens, finish)
          alias_index = next_significant(tokens, alias_index) \
            if alias_index && tokens[alias_index].text.casecmp?('AS')
          explicit_alias = alias_index && identifier?(tokens[alias_index]) &&
                           !ALIAS_STOP_WORDS.include?(tokens[alias_index].text.upcase)
          alias_name = explicit_alias ? identifier_text(tokens[alias_index]) : info.fetch(:entity_name)
          aliases[alias_name.downcase] = info
          aliases[original.downcase] = info
          aliases[info.fetch(:qualified_name).downcase] = info
        end
        return 'SQL query does not reference a convertible Module.Entity source' if aliases.empty?

        aliases
      end

      def table_start_indices(tokens)
        starts = []
        active_from = {}
        join_constraint = {}
        depth = 0
        significant_indices(tokens).each do |index|
          token = tokens[index]
          if token.text == ')'
            active_from.delete(depth)
            depth -= 1
            next
          end
          if token.type == :word
            word = token.text.upcase
            if word == 'FROM'
              active_from[depth] = true
              join_constraint[depth] = false
              starts << next_significant(tokens, index)
            elsif word == 'JOIN'
              join_constraint[depth] = false
              starts << next_significant(tokens, index)
            elsif word == 'ON'
              join_constraint[depth] = true
            elsif STOP_CLAUSES.include?(word)
              active_from.delete(depth)
              join_constraint.delete(depth)
            end
          elsif token.text == ',' && active_from[depth] && !join_constraint[depth]
            starts << next_significant(tokens, index)
          end
          depth += 1 if token.text == '('
        end
        starts.compact.uniq
      end

      def parse_table(tokens, start)
        first = tokens[start]
        return unless identifier?(first)

        first_text = identifier_text(first)
        dot = next_significant(tokens, start)
        second = dot && next_significant(tokens, dot)
        if second && tokens[dot].text == '.' && identifier?(tokens[second])
          second_text = identifier_text(tokens[second])
          if physical_name?(second_text) && (SCHEMAS.include?(first_text.downcase) || catalog_entry(second_text))
            info, warnings = resolve_table(second_text)
            return unless info

            warnings << "SQL schema #{first_text} was removed from the logical OQL entity name"
            return [info, second, second_text, warnings]
          end
          info, warnings = resolve_table("#{first_text}.#{second_text}")
          return info && [info, second, "#{first_text}.#{second_text}", warnings]
        end

        info, warnings = resolve_table(first_text)
        info && [info, start, first_text, warnings]
      end

      def resolve_table(value)
        canonical = catalog_entry(value)
        return [canonical, []] if canonical

        parts = if value.include?('$')
                  value.split('$', 2)
                elsif value.include?('.')
                  value.split('.', 2)
                end
        return [nil, []] unless parts&.size == 2 && parts.none?(&:empty?)

        qualified = parts.join('.')
        info = entity_info(qualified)
        warning = if value.include?('$')
                    "logical entity casing was inferred from physical table #{value}; use --project for canonical names"
                  end
        [info, Array(warning)]
      end

      def translate_attributes!(tokens, aliases)
        significant_indices(tokens).each do |index|
          token = tokens[index]
          next unless identifier?(token)

          info = aliases[identifier_text(token).downcase]
          next unless info

          separator = next_significant(tokens, index)
          attribute = separator && next_significant(tokens, separator)
          next unless attribute && tokens[separator].text == '.' &&
                      (identifier?(tokens[attribute]) || tokens[attribute].text == '*')

          name = tokens[attribute].text == '*' ? '*' : canonical_attribute(info, identifier_text(tokens[attribute]))
          tokens[separator] = Translator::Token.new(:path_separator, '/')
          tokens[attribute] = Translator::Token.new(:word, name == '*' ? name : quote_identifier(name))
        end
      end

      def translate_function_aliases!(tokens)
        tokens.each_index do |index|
          token = tokens[index]
          next unless token.type == :word

          replacement = FUNCTION_ALIASES[token.text.upcase]
          tokens[index] = Translator::Token.new(:word, replacement) if replacement
        end
      end

      def translate_operators!(tokens)
        tokens.each_index do |index|
          token = tokens[index]
          tokens[index] = Translator::Token.new(:symbol, ':') \
            if token.type == :symbol && token.text == '/'
        end
        significant_indices(tokens).each_cons(2) do |left, right|
          next unless tokens[left].text == '<' && tokens[right].text == '>'

          tokens[left] = Translator::Token.new(:symbol, '!')
          tokens[right] = Translator::Token.new(:symbol, '=')
        end
      end

      def translate_parameters!(tokens)
        parameters = []
        tokens.each_index do |index|
          token = tokens[index]
          if token.type == :parameter
            parameters << token.text.delete_prefix('$')
            next
          end
          next unless %w[: @].include?(token.text)

          name_index = next_significant(tokens, index)
          return 'named SQL parameter is missing its name' unless name_index && tokens[name_index].type == :word

          name = tokens[name_index].text
          tokens[index] = Translator::Token.new(:parameter, "$#{name}")
          tokens[name_index] = Translator::Token.new(:word, '')
          parameters << name
        end
        parameters.uniq
      end

      def entity_catalog(project)
        return {} unless project

        project.modules.each_with_object({}) do |mod, catalog|
          mod.entities.each do |entity|
            qualified = entity.qualified_name || "#{mod.name}.#{entity.name}"
            info = entity_info(qualified, entity.attributes)
            catalog[qualified.downcase] = info
            catalog[qualified.tr('.', '$').downcase] = info
          end
        end
      end

      def entity_info(qualified, attributes = [])
        module_name, entity_name = qualified.split('.', 2)
        {
          qualified_name: "#{module_name}.#{entity_name}", module_name:, entity_name:,
          attributes: attributes.to_h { [_1.name.to_s.downcase, _1.name.to_s] }
        }
      end

      def catalog_entry(value) = @catalog[value.to_s.downcase]
      def physical_name?(value) = value.include?('$')

      def canonical_attribute(info, name)
        info.fetch(:attributes).fetch(name.downcase, name)
      end

      def render_qualified(value)
        value.split('.', 2).map { quote_identifier(_1) }.join('.')
      end

      def quote_identifier(value)
        return value if value.match?(/\A[A-Za-z_][A-Za-z0-9_$]*\z/) && !RESERVED.include?(value.upcase)

        %("#{value.gsub('"', '""')}")
      end

      def identifier?(token) = token && %i[word quoted_identifier].include?(token.type)

      def identifier_text(token)
        text = token.text
        return text[1...-1].gsub(']]', ']') if text.start_with?('[') && text.end_with?(']')
        return text[1...-1].gsub('""', '"') if text.start_with?('"') && text.end_with?('"')

        text
      end

      def significant_indices(tokens)
        tokens.each_index.reject { %i[space comment].include?(tokens[_1].type) || tokens[_1].text.empty? }
      end

      def next_significant(tokens, index)
        ((index + 1)...tokens.length).find do |candidate|
          !%i[space comment].include?(tokens[candidate].type) && !tokens[candidate].text.empty?
        end
      end

      def adjacent_symbols?(tokens, first, second)
        significant = significant_indices(tokens)
        significant.each_cons(2).any? do |left, right|
          tokens[left].text == first && tokens[right].text == second
        end
      end

      def adjacent_words?(tokens, first, second)
        significant = significant_indices(tokens)
        significant.each_cons(2).any? do |left, right|
          tokens[left].type == :word && tokens[right].type == :word &&
            tokens[left].text.casecmp?(first) && tokens[right].text.casecmp?(second)
        end
      end

      def table_subquery?(tokens)
        significant = significant_indices(tokens)
        significant.each_cons(2).any? do |left, right|
          tokens[left].type == :word && %w[FROM JOIN].include?(tokens[left].text.upcase) &&
            tokens[right].text == '('
        end
      end

      def unsupported_function(tokens)
        significant = significant_indices(tokens)
        significant.each_cons(2).filter_map do |name, opening|
          next unless identifier?(tokens[name]) && tokens[opening].text == '('

          function = identifier_text(tokens[name]).upcase
          function unless FUNCTIONS.include?(function) || FUNCTION_LIKE_OPERATORS.include?(function)
        end.first
      end

      def unsupported_operator?(tokens)
        [%w[| |], %w[- >], %w[# >]].any? do |first, second|
          adjacent_symbols?(tokens, first, second)
        end || significant_indices(tokens).any? { %w[& ^].include?(tokens[_1].text) }
      end

      def keyword?(tokens, word)
        significant_indices(tokens).any? do |index|
          tokens[index].type == :word && tokens[index].text.casecmp?(word)
        end
      end

      def postgres_positional_parameter?(tokens)
        significant = significant_indices(tokens)
        significant.each_cons(2).any? do |left, right|
          tokens[left].text == '$' && tokens[right].text.match?(/\A\d\z/)
        end
      end

      def unsupported(sql, warning)
        OqlProjection.new(sql.freeze, nil, @dialect, :unsupported, [warning].freeze, [].freeze)
      end
    end
    # rubocop:enable Metrics
  end
end
