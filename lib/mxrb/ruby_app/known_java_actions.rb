# frozen_string_literal: true

require 'digest'

module Mxrb
  module RubyApp
    # Source-pinned compatibility adapters, not a general HTML security API.
    # Customized or missing Java implementations require an explicit adapter.
    module KnownJavaActions
      SOURCES = {
        'ValidateEmail' => %w[
          b8f95d3bf443c3cfc8225d8c3c48f18f5dc3872c9ae3b5034caeedc8f2df640e
          d75e3ac4a02f6a33f8a9fa3612221dcac3214d2048dd6ebda66edb0e45c657cd
        ],
        'XSS_Sanitizer' => %w[
          d5d1b2840089a2538afdcdb9ff761464959fe775b4793d900df8fe9ddb963aea
          9ea2c79552f8e3844fca7f59e39a114504fb1ea97a7bb904bbaa6a22345eeead
        ]
      }.freeze
      EMAIL = %r{\A[a-zA-Z0-9.!\#$%&'*+/=?^_`{|}~-]+@
                 (?:\[[0-9]{1,3}(?:\.[0-9]{1,3}){3}\]|(?:[a-zA-Z0-9-]+\.)+[a-zA-Z]{2,})\z}x
      JAVA_DOT = '[^\n\r\u0085\u2028\u2029]'
      CONTENT_TAGS = %w[script iframe object embed applet].map do |tag|
        name = tag.chars.map { "[#{_1}#{_1.upcase}]" }.join
        Regexp.new("<#{name}[^>]*>#{JAVA_DOT}*?</#{name}>")
      end.freeze
      JAVASCRIPT = /[jJ][aA][vV][aA][sS][cC][rR][iI][pP][tT]:/
      META = /<[mM][eE][tT][aA][^>]*[hH][tT][tT][pP]-[eE][qQ][uU][iI][vV][^>]*>/

      module_function

      def registrations(directory)
        SOURCES.filter_map do |name, hashes|
          path = File.join(directory, 'javasource', 'feedbackmodule', 'actions', "#{name}.java")
          next unless File.file?(path)
          next unless hashes.include?(Digest::SHA256.hexdigest(File.binread(path).gsub("\r\n", "\n")))

          "Mxrb::RubyApp::KnownJavaActions.register(#{name.inspect})"
        end.join("\n")
      end

      def register(name)
        handler = { 'ValidateEmail' => method(:validate_email), 'XSS_Sanitizer' => method(:sanitize) }.fetch(name)
        Registry.register_java_custom_action("FeedbackModule.#{name}", handler)
      end

      def validate_email(arguments)
        value = arguments.fetch('EmailAddress')
        raise TypeError, 'EmailAddress must be a String' unless value.is_a?(String)

        EMAIL.match?(value)
      end

      def sanitize(arguments)
        value = arguments.fetch('stringToSanitize')
        return value if value.nil? || value.empty?

        value = value.gsub(CONTENT_TAGS.first, '')
        value = value.gsub(/(?<![a-zA-Z0-9_])[oO][nN]\w+\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)/, '')
        value = value.gsub(JAVASCRIPT, '')
        CONTENT_TAGS.drop(1).each { value = value.gsub(_1, '') }
        value.gsub(META, '').gsub(/<[^>]*(>|\z)/, '')
      end
    end
  end
end
