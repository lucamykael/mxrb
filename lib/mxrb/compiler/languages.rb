# frozen_string_literal: true

require 'json'

module Mxrb
  module Compiler
    # The description and writing direction the Runtime model gives each
    # language a project declares, as MxBuild 10.24.0 and 11.12.1 wrote them
    # for every language code they accept (schemas/languages-*.json). Versions
    # before 10 use the 10.24.0 table, the nearest one audited.
    module Languages
      TABLES = { 10 => 'languages-10.24.0.73019.json', 11 => 'languages-11.12.1.json' }.freeze

      module_function

      # { 'description' => 'English, United States', 'rtl' => false } of a code.
      def entry(code, version)
        table(version).fetch(code.to_s) do
          raise CompilationError, "language #{code} is not one MxBuild #{version} accepts"
        end
      end

      def table(version)
        major = Integer(version.to_s.split('.').first)
        file = TABLES.fetch(major >= 11 ? 11 : 10)
        (@tables ||= {})[file] ||= JSON.parse(File.read(File.join(__dir__, 'schemas', file))).freeze
      end
    end
  end
end
