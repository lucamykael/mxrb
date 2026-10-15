# frozen_string_literal: true

require_relative 'time_zones'

module Mxrb
  module Runtime
    # The microflows a Mendix Runtime runs when it starts and before it stops.
    module Lifecycle
      KEYS = { 'after_startup' => 'AfterStartupMicroflow', 'before_shutdown' => 'BeforeShutdownMicroflow' }.freeze

      module_function

      def settings(project)
        return project.lifecycle_settings if project.respond_to?(:lifecycle_settings)

        model = TimeZones.model_settings(project)
        KEYS.to_h { |key, setting| [key, model[setting].to_s] }.reject { |_, name| name.empty? }
      end
    end
  end
end
