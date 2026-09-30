# frozen_string_literal: true

require 'mxrb'

# rubocop:disable Metrics/MethodLength
# Builds the official-MxBuild witness for editable annotation connections.
module AnnotationFlowsFixture
  VERSION = '11.12.1'

  module_function

  def build(destination)
    Mxrb.define(destination) do
      mendix_version VERSION
      self.module :AnnotationFlows do
        page(:Home) { title 'Annotation flow certification' }
        microflow :Connected do
          annotation 'Navigate to the home page', position: '20;30', size: '240;80'
          as_node :note
          show_home_page
          as_node :home_action
          annotation_flow from: :note, to: :home_action
        end
      end
      navigation do
        profile :Responsive, home_page: 'AnnotationFlows.Home', app_title: 'Annotation flows'
      end
    end
  end
end

AnnotationFlowsFixture.build(ARGV.fetch(0)) if $PROGRAM_NAME == __FILE__
# rubocop:enable Metrics/MethodLength
