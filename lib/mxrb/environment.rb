# frozen_string_literal: true

require 'monitor'

module Mxrb
  # Immutable, stdlib-only environment configuration. Loading never mutates
  # process ENV; apply and with are the explicit mutation boundaries.
  class Environment # rubocop:disable Metrics/ClassLength
    class Error < StandardError; end
    class InvalidName < ArgumentError; end

    # Syntax error with location but never with the offending secret value.
    class ParseError < Error
      attr_reader :path, :line

      def initialize(path, line, reason)
        @path = path
        @line = line
        super("invalid environment file #{path}:#{line}: #{reason}")
      end
    end

    NAME_PATTERN = /\A[a-z][a-z0-9_-]*\z/
    KEY_PATTERN = /\A[A-Za-z_][A-Za-z0-9_]*\z/
    ALIASES = {
      'dev' => 'development',
      'development' => 'development',
      'qa' => 'qa',
      'homolog' => 'staging',
      'homologation' => 'staging',
      'staging' => 'staging',
      'prod' => 'production',
      'production' => 'production'
    }.freeze
    PROFILE_KEYS = %w[MXRB_ENV RACK_ENV RAILS_ENV].freeze
    WITH_MONITOR = Monitor.new
    UNSET = Object.new.freeze

    attr_reader :name, :requested_name, :root, :sources

    def self.load(name = nil, root: Dir.pwd, process: ENV)
      new(name, root:, process:)
    end

    def initialize(name = nil, root: Dir.pwd, process: ENV)
      @root = File.expand_path(root)
      @process = stringify(process)
      @requested_name = validate_name(name || detected_name)
      @name = ALIASES.fetch(@requested_name, @requested_name)
      @sources = existing_sources.freeze
      @values = load_values.freeze
    end

    def fetch(key, default = UNSET, &block)
      normalized = key.to_s
      return @values.fetch(normalized, &block) if block
      return @values.fetch(normalized) if default.equal?(UNSET)

      @values.fetch(normalized, default)
    end

    def [](key) = @values[key.to_s]
    def key?(key) = @values.key?(key.to_s)

    def to_h = @values.dup

    # Applies to ENV by default only when explicitly called. overwrite: false
    # preserves keys already present in the target.
    def apply(target = ENV, overwrite: true)
      @values.each do |key, value|
        next if !overwrite && target.key?(key)

        target[key] = value
      end
      target
    end

    # Applies the configuration for one block and restores the target even if
    # the block raises. Calls are serialized because process ENV is global.
    def with(target = ENV, overwrite: true)
      WITH_MONITOR.synchronize do
        snapshot = snapshot(target, overwrite:)
        apply(target, overwrite:)
        begin
          yield self
        ensure
          restore(target, snapshot)
        end
      end
    end

    def inspect
      "#<#{self.class} name=#{name.inspect} root=#{root.inspect} " \
        "sources=#{sources.size} keys=#{@values.size}>"
    end

    private

    def detected_name
      PROFILE_KEYS.each do |key|
        value = @process[key].to_s.strip
        return value unless value.empty?
      end
      'development'
    end

    def validate_name(raw)
      candidate = raw.to_s.strip.downcase
      raise InvalidName, "invalid environment name #{raw.inspect}" unless NAME_PATTERN.match?(candidate)

      candidate.freeze
    end

    def candidate_sources
      [
        File.join(root, '.env'),
        File.join(root, ".env.#{name}"),
        File.join(root, 'config', 'environments', "#{name}.env")
      ]
    end

    def existing_sources = candidate_sources.select { File.file?(_1) }

    def load_values
      loaded = sources.each_with_object({}) do |path, values|
        values.update(Parser.new(path).parse)
      end
      immutable(loaded.merge(@process))
    end

    def stringify(values)
      immutable(values.to_h.to_h { |key, value| [key.to_s, value.to_s] })
    end

    def immutable(values)
      values.to_h do |key, value|
        [key.to_s.dup.freeze, value.to_s.dup.freeze]
      end.freeze
    end

    def snapshot(target, overwrite:)
      keys = overwrite ? @values.keys : @values.keys.reject { target.key?(_1) }
      keys.to_h do |key|
        [key, target.key?(key) ? [:present, target[key]] : [:missing, nil]]
      end
    end

    def restore(target, snapshot)
      snapshot.each do |key, (state, value)|
        state == :present ? target[key] = value : target.delete(key)
      end
    end

    # A deliberately non-shell parser: values are read as data and variable,
    # command, or backtick expansion is never performed.
    class Parser
      def initialize(path)
        @path = path
      end

      def parse
        File.foreach(@path, encoding: 'bom|utf-8').with_index(1).each_with_object({}) do |(line, number), result|
          parse_line(line, number, result)
        end
      rescue ArgumentError, EncodingError => e
        raise ParseError.new(@path, 1, e.message), cause: e
      end

      private

      def parse_line(line, number, result)
        source = line.strip
        return if source.empty? || source.start_with?('#')

        source = source.delete_prefix('export ').lstrip
        key, raw = source.split('=', 2)
        key = key.to_s.strip
        error(number, 'expected KEY=VALUE') if raw.nil? || !KEY_PATTERN.match?(key)
        result[key] = parse_value(raw.lstrip, number)
      end

      def parse_value(source, number)
        return '' if source.empty?
        return quoted_value(source, number, "'") if source.start_with?("'")
        return quoted_value(source, number, '"') if source.start_with?('"')

        source.sub(/\s+#.*\z/, '').rstrip
      end

      def quoted_value(source, number, quote)
        value, remainder = extract_quoted(source, quote)
        error(number, 'unterminated quoted value') unless remainder
        error(number, 'unexpected content after quoted value') unless remainder.strip.match?(/\A(?:#.*)?\z/)

        quote == '"' ? unescape_double(value) : value
      end

      def extract_quoted(source, quote) # rubocop:disable Metrics/MethodLength
        escaped = false
        source.each_char.with_index do |character, index|
          if escaped
            escaped = false
            next
          end

          if character == '\\' && quote == '"'
            escaped = true
          elsif character == quote && index.positive?
            return [source[1...index], source[(index + 1)..]]
          end
        end
        [nil, nil]
      end

      def unescape_double(value)
        value.gsub(/\\([nrt"\\])/) do
          { 'n' => "\n", 'r' => "\r", 't' => "\t", '"' => '"', '\\' => '\\' }.fetch(Regexp.last_match(1))
        end
      end

      def error(line, reason)
        raise ParseError.new(@path, line, reason)
      end
    end
  end
end
