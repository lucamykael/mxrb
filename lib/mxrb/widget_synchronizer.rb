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
      plan = Runtime::Toolchain.new(@project).plan
      raise ArgumentError, "Mendix toolchain not found: #{plan.mx_path}" unless File.executable?(plan.mx_path)

      update_widgets!(plan.mx_path)
      generate
      update_widgets!(plan.mx_path)
      Result.new(@definition, @project, plan.mx_path)
    end

    private

    def generate
      previous = ENV['MXRB_OUTPUT_PATH']
      ENV['MXRB_OUTPUT_PATH'] = @project
      load @definition
    ensure
      previous ? ENV['MXRB_OUTPUT_PATH'] = previous : ENV.delete('MXRB_OUTPUT_PATH')
    end

    def update_widgets!(mx_path)
      success = system(mx_path, 'update-widgets', @project)
      raise Error, 'Mendix widget synchronization failed' unless success
    end
  end
end
