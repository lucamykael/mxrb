# frozen_string_literal: true

module Mxrb
  module Runtime
    # Java regular expressions (java.util.regex.Pattern), which Mendix uses for
    # validation rules and isMatch/replaceAll/replaceFirst, as Ruby Regexps.
    # Where the syntaxes read the same text differently, the pattern is
    # rewritten: "." and "$" end at any Java line terminator, "^" and "$" anchor
    # the input unless (?m), POSIX classes such as \p{Alpha} are ASCII, and
    # \h, \v, \Q...\E and \x{...} keep their Java meaning. A construct with no
    # faithful equivalent fails instead of matching differently.
    module JavaRegex
      LINE_TERMINATORS = '\n\r\u0085\u2028\u2029'
      HORIZONTAL = ' \t\u00A0\u1680\u180E\u2000-\u200A\u202F\u205F\u3000'
      VERTICAL = '\n\u000B\f\r\u0085\u2028\u2029'
      # Java's POSIX classes, without UNICODE_CHARACTER_CLASS, are US-ASCII.
      POSIX = {
        'Lower' => 'a-z', 'Upper' => 'A-Z', 'ASCII' => '\x00-\x7F', 'Alpha' => 'a-zA-Z', 'Digit' => '0-9',
        'Alnum' => 'a-zA-Z0-9', 'Punct' => '!-\/:-@\[-`{-~', 'Graph' => '!-~', 'Print' => ' -~',
        'Blank' => ' \t', 'Cntrl' => '\x00-\x1F\x7F', 'XDigit' => '0-9a-fA-F', 'Space' => ' \t\n\x0B\f\r'
      }.freeze
      UNSUPPORTED = { 'U' => 'UNICODE_CHARACTER_CLASS', 'c' => 'CANON_EQ' }.freeze
      @cache = {}
      @cache_lock = Mutex.new

      module_function

      # Whether the whole value matches, as Pattern.matches does.
      def matches?(source, value) = compiled(source, whole: true).match?(value.to_s)

      def regexp(source) = compiled(source, whole: false)

      def compiled(source, whole:)
        @cache_lock.synchronize do
          @cache[[source, whole]] ||= quietly do
            translated = translate(source)
            Regexp.new(whole ? "\\A(?:#{translated})\\z" : translated)
          end
        end
      rescue RegexpError => e
        raise ArgumentError, "invalid regular expression #{source.inspect}: #{e.message}"
      end

      def translate(source) = Translator.new(source.to_s).call

      # A pattern from the model, such as [\w0-9], is not a mistake to warn about.
      def quietly
        verbose = $VERBOSE
        $VERBOSE = nil
        yield
      ensure
        $VERBOSE = verbose
      end

      # Walks the pattern once, keeping the flags of each group and whether it
      # is inside a character class. The scanner keeps one branch per construct.
      class Translator # rubocop:disable Metrics/ClassLength
        def initialize(source)
          @source = source
          @index = 0
          @out = +''
          @class_depth = 0
          @flags = [{ dotall: false, multiline: false, unix: false }]
        end

        def call
          step while @index < @source.length
          @out
        end

        private

        def step # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength
          char = @source[@index]
          case char
          when '\\' then escape
          when '[' then open_class
          when ']' then close_class
          when '(' then open_group
          when ')' then close_group
          when '.' then literal_or(char, @class_depth.positive? ? char : dot)
          when '^' then literal_or(char, @class_depth.positive? ? char : caret)
          when '$' then literal_or(char, @class_depth.positive? ? char : dollar)
          else literal_or(char, char)
          end
        end

        def literal_or(_char, text)
          @out << text
          @index += 1
        end

        def flags = @flags.last
        def terminators = flags[:unix] ? '\n' : LINE_TERMINATORS

        def dot = flags[:dotall] ? '(?m:.)' : "[^#{terminators}]"
        def caret = flags[:multiline] ? "(?:\\A|(?<=[#{terminators}]))" : '\A'

        def dollar
          return "(?=[#{terminators}]|\\z)" if flags[:multiline]

          "(?=(?:#{flags[:unix] ? '\n' : '\r\n|[\n\r\u0085\u2028\u2029]'})?\\z)"
        end

        def open_class
          @class_depth += 1
          @out << '['
          @index += 1
          return unless @source[@index] == '^'

          @out << '^'
          @index += 1
        end

        def close_class
          @class_depth -= 1 if @class_depth.positive?
          literal_or(']', ']')
        end

        def open_group
          return literal_or('(', '(') if @class_depth.positive?

          @index += 1
          match = /\A\?([a-zA-Z]*)(?:-([a-zA-Z]*))?(:|\))/.match(@source[@index..])
          return group_with_flags(match) if match && !match[0].start_with?('?<') && flag_group?(match)

          @flags.push(flags.dup)
          @out << '('
        end

        def flag_group?(match) = !(match[1] + match[2].to_s).empty?

        # (?flags) changes the enclosing group's flags; (?flags:...) only its own.
        def group_with_flags(match) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
          @index += match[0].length
          updated = apply_flags(flags.dup, match[1], true)
          updated = apply_flags(updated, match[2].to_s, false)
          ruby = ruby_flags(match[1], match[2].to_s)
          if match[3] == ')'
            @flags[-1] = updated
            @out << "(?#{ruby})" unless ruby.empty? || ruby == '-'
          else
            @flags.push(updated)
            @out << "(?#{ruby}:"
          end
        end

        def apply_flags(state, letters, on)
          letters.each_char do |letter|
            raise ArgumentError, "Java regular expression flag #{UNSUPPORTED[letter]} is not supported" \
              if UNSUPPORTED.key?(letter)

            state[:dotall] = on if letter == 's'
            state[:multiline] = on if letter == 'm'
            state[:unix] = on if letter == 'd'
          end
          state
        end

        # Ruby keeps i and x; s, m and d are rewritten into the pattern itself.
        def ruby_flags(on, off)
          kept_on = on.delete('smdu')
          kept_off = off.delete('smdu')
          kept_off.empty? ? kept_on : "#{kept_on}-#{kept_off}"
        end

        def close_group
          @flags.pop if @class_depth.zero? && @flags.length > 1
          literal_or(')', ')')
        end

        def escape # rubocop:disable Metrics/CyclomaticComplexity, Metrics/MethodLength
          letter = @source[@index + 1]
          raise ArgumentError, 'a regular expression cannot end with a backslash' if letter.nil?

          @index += 2
          @out << case letter
                  when 'Q' then quoted
                  when 'h' then class_text(HORIZONTAL, negated: false)
                  when 'H' then class_text(HORIZONTAL, negated: true)
                  when 'v' then class_text(VERTICAL, negated: false)
                  when 'V' then class_text(VERTICAL, negated: true)
                  when 'x' then hexadecimal
                  when 'p', 'P' then property(letter == 'P')
                  else "\\#{letter}"
                  end
        end

        def quoted
          finish = @source.index('\\E', @index) || @source.length
          text = @source[@index...finish]
          @index = [finish + 2, @source.length].min
          @class_depth.positive? ? text.chars.map { Regexp.escape(_1) }.join : Regexp.escape(text)
        end

        def class_text(members, negated:)
          return "[#{negated ? '^' : ''}#{members}]" if @class_depth.zero?
          raise ArgumentError, 'a negated \\h, \\v or POSIX class inside a character class is not supported' if negated

          members
        end

        def hexadecimal
          return '\\x' unless @source[@index] == '{'

          finish = @source.index('}', @index)
          raise ArgumentError, 'unterminated \\x{...}' unless finish

          digits = @source[(@index + 1)...finish]
          @index = finish + 1
          "\\u{#{digits}}"
        end

        def property(negated)
          name = if @source[@index] == '{'
                   finish = @source.index('}', @index)
                   raise ArgumentError, 'unterminated \\p{...}' unless finish

                   @source[(@index + 1)...finish].tap { @index = finish + 1 }
                 else
                   @source[@index].tap { @index += 1 }
                 end
          property_text(name, negated)
        end

        def property_text(name, negated)
          return class_text(POSIX[name], negated:) if POSIX.key?(name)
          raise ArgumentError, "Java property \\p{#{name}} is not supported" if name.start_with?('java')

          "\\#{negated ? 'P' : 'p'}{#{ruby_property(name)}}"
        end

        # \p{IsLatin} is the Latin script and \p{InBasicLatin} the Basic Latin
        # block, which Ruby names Latin and In_Basic_Latin.
        def ruby_property(name)
          return name.delete_prefix('Is') if name.match?(/\AIs\p{Upper}/)
          return name unless name.match?(/\AIn\p{Upper}/)

          "In_#{name.delete_prefix('In').gsub(/(?<=[a-z])(?=[A-Z])/, '_')}"
        end
      end
    end
  end
end
