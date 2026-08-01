# frozen_string_literal: true

module Mxrb
  # Generates a project around Mendix's widget schema synchronization pass.
  class WidgetSynchronizer
    Result = Data.define(:definition, :project, :mx_path)

    def initialize(definition, project)
      @definition = File.expand_path(definition)
      @project = File.expand_path(project)
    end

    def sync!
      raise ArgumentError, "definition not found: #{@definition}" unless File.file?(@definition)

      generate
      generate
      Result.new(@definition, @project, 'native MPK schemas')
    end

    private

    def generate
      previous = ENV['MXRB_OUTPUT_PATH']
      ENV['MXRB_OUTPUT_PATH'] = @project
      load @definition
    ensure
      previous ? ENV['MXRB_OUTPUT_PATH'] = previous : ENV.delete('MXRB_OUTPUT_PATH')
    end
  end
end
