# frozen_string_literal: true

require 'ripper'

module Mxrb
  # Measures storage-level noise that leaked into an exported, public Ruby tree.
  # Keyword arguments are intentionally not violations; explicit Hash literals
  # are, because callers would otherwise have to edit serialized structures.
  class PublicSourceAudit # rubocop:disable Metrics/ClassLength
    UUID = /\b[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\b/i
    DIGEST = /\b(?:[0-9a-f]{40}|[0-9a-f]{64})\b/i
    UNIT_IDENTITY_NAMES = %w[unit_id container_id mendix_id].freeze
    OPAQUE_API_NAMES = %w[
      native_fragment native_fragments native_unit native_units native_widget native_widgets
      native_document native_documents form_structure deep_structure bson_binary TypePointer
    ].freeze
    STORAGE_SCHEMA = /(?:
      ["']\$(?:ID|Type)["'] |
      \b(?:node_type|fields|collection|marker): |
      :(?:node_type|fields|collection|marker)\b
    )/x
    SIDECAR_REFERENCE = %r{(?:File\.join\([^\n]*["']\.mxrb["']|["']\.mxrb/)}
    TEXT_PATTERNS = {
      uuid: UUID, digest: DIGEST, storage_schema: STORAGE_SCHEMA,
      sidecar_reference: SIDECAR_REFERENCE
    }.freeze

    Violation = Data.define(:category, :subsystem, :path, :line, :excerpt) do
      def to_h = { category:, subsystem:, path:, line:, excerpt: }
    end

    attr_reader :root, :violations

    def initialize(root, include_internal: false)
      @root = File.expand_path(root)
      @include_internal = include_internal
      @violations = scan.freeze
    end

    def clean? = violations.empty?

    def summary
      violations.group_by(&:category).transform_values(&:size).sort.to_h
    end

    def by_subsystem
      violations.group_by(&:subsystem).transform_values do |entries|
        entries.group_by(&:category).transform_values(&:size).sort.to_h
      end.sort.to_h
    end

    def to_h
      {
        root:, clean: clean?, files: source_paths.size, total: violations.size,
        summary:, subsystems: by_subsystem,
        violations: violations.map(&:to_h)
      }
    end

    private

    def scan
      source_paths.flat_map do |path|
        relative = path.delete_prefix("#{root}/")
        scan_source(File.read(path), relative)
      end
    end

    def source_paths
      @source_paths ||= Dir.glob(File.join(root, '**', '*.rb'), File::FNM_DOTMATCH).sort.reject do |path|
        !@include_internal && path.delete_prefix("#{root}/").start_with?('.mxrb/')
      end
    end

    def scan_source(source, relative)
      subsystem = subsystem_for(relative)
      lines = source.lines
      violations = ast_hashes(source, relative, subsystem, lines)
      violations.concat(pattern_violations(source, relative, subsystem, lines))
      violations << violation(:syntax_error, subsystem, relative, 1, lines) unless Ripper.sexp(source)
      violations
    end

    def ast_hashes(source, relative, subsystem, lines)
      sexp = Ripper.sexp(source)
      return [] unless sexp

      find_nodes(sexp, :hash).map do |node|
        line = first_location(node)&.first || 1
        violation(:hash_literal, subsystem, relative, line, lines)
      end
    end

    def pattern_violations(source, relative, subsystem, lines)
      lexical_violations(source, relative, subsystem, lines) + TEXT_PATTERNS.flat_map do |category, pattern|
        scan_pattern(source, pattern).map do |line|
          violation(category, subsystem, relative, line, lines)
        end
      end
    end

    def scan_pattern(source, pattern)
      source.enum_for(:scan, pattern).map do
        offset = Regexp.last_match.begin(0)
        source[0...offset].count("\n") + 1
      end
    end

    def lexical_violations(source, relative, subsystem, lines)
      Ripper.lex(source).filter_map do |(position, event, token, _state)|
        category = lexical_category(event, token)
        next unless category

        line = position.first
        violation(category, subsystem, relative, line, lines)
      end
    end

    def lexical_category(event, token)
      return :hash_rocket if event == :on_op && token == '=>'
      return unless %i[on_ident on_label].include?(event)

      name = token.delete_suffix(':')
      return :unit_identity if UNIT_IDENTITY_NAMES.include?(name)

      :opaque_api if OPAQUE_API_NAMES.include?(name)
    end

    def find_nodes(value, type, found = [])
      return found unless value.is_a?(Array)

      found << value if value.first == type
      value.each { find_nodes(_1, type, found) if _1.is_a?(Array) }
      found
    end

    def first_location(value)
      return unless value.is_a?(Array)
      return value[2] if value.first.to_s.start_with?('@') && value[2].is_a?(Array)

      value.each do |child|
        location = first_location(child)
        return location if location
      end
      nil
    end

    def violation(category, subsystem, relative, line, lines)
      Violation.new(
        category:, subsystem:, path: relative, line:,
        excerpt: lines.fetch(line - 1, '').strip
      )
    end

    def subsystem_for(relative)
      parts = relative.split('/')
      return 'project' if parts.one?
      return 'internal_sidecar' if parts.first == '.mxrb'
      return "app/#{parts.fetch(1, 'other')}" if parts.first == 'app'

      if parts.first == 'modules'
        layer = parts.fetch(2, 'module')
        return "modules/#{layer}"
      end

      parts.first
    end
  end
end
