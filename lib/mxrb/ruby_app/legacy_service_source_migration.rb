# frozen_string_literal: true

module Mxrb
  module RubyApp
    # Renames the deprecated service projection API while preserving embedded
    # application code byte-for-byte everywhere else.
    class LegacyServiceSourceMigration
      SERVICE_PATH = %r{\Aapp/services/.+\.rb\z}
      NATIVE_FLOW = /\bnative(?=\s*(?:\(\s*)?:(?:microflow|nanoflow)\b)/
      NATIVE_CALL = /\bnative_call\b/

      def initialize(path:, source:)
        @path = path.to_s
        @source = source.to_s
      end

      def migrate
        return @source unless SERVICE_PATH.match?(@path)

        @source.gsub(NATIVE_FLOW, 'flow').gsub(NATIVE_CALL, 'execute_flow')
      end
    end
  end
end
