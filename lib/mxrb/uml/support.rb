# frozen_string_literal: true

require 'digest'

module Mxrb
  module Uml
    # Shared, deterministic escaping and identifier helpers for text formats.
    module Support
      module_function

      def identifier(value, prefix: 'n')
        raw = value.to_s
        body = raw.gsub(/[^A-Za-z0-9_]/, '_')
        body = prefix if body.empty?
        body = "#{prefix}_#{body}" unless body.match?(/\A[A-Za-z_]/)
        body += "_#{Digest::SHA256.hexdigest(raw)[0, 8]}" unless body == raw
        body
      end

      def mermaid_text(value)
        value.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
             .gsub('"', '&quot;').gsub(/[\r\n]+/, ' ')
      end

      def plantuml_text(value)
        value.to_s.gsub('\\') { '\\\\' }.gsub('"', '\\"').gsub(/[\r\n]+/, ' ')
      end

      def words(value)
        value.to_s.delete_prefix('Microflows$').delete_suffix('Action')
             .gsub(/([a-z0-9])([A-Z])/, '\\1 \\2').tr('_', ' ').strip
      end
    end
  end
end
