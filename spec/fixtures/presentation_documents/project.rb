# frozen_string_literal: true

require 'mxrb'

# rubocop:disable Metrics/AbcSize, Metrics/BlockLength, Metrics/MethodLength, Metrics/ModuleLength
module PresentationDocumentsFixture
  VERSION = '11.12.1'

  module_function

  def build(destination)
    preview = File.join(__dir__, 'preview.bin')
    Mxrb.define(destination) do
      mendix_version VERSION

      self.module :Presentation do
        page :Home do
          title 'Presentation documents certification'
          text :Introduction, caption: 'Reusable presentation documents are native Ruby.'
        end

        layout_document :Shell do
          name 'Shell'
          documentation 'Typed reusable layout'
          excluded false
          export_level :hidden
          canvas_width 800
          canvas_height 600
          content(:web_layout_content) do
            layout_type :responsive
            layout_call nil
            widgets(:placeholder) do
              name 'Main'
              appearance do
                css_class 'shell-content'
                style ''
                set :design_properties, []
                dynamic_classes ''
              end
              tab_index 0
            end
          end
          appearance do
            css_class 'shell-layout'
            style ''
            set :design_properties, []
            dynamic_classes ''
          end
        end

        page_template_document :Starter do
          name 'Starter'
          documentation 'Typed reusable page template'
          excluded false
          export_level :hidden
          canvas_width 800
          canvas_height 600
          display_name 'Starter'
          documentation_url ''
          template_category 'General'
          template_category_weight 1
          layout_call do
            layout 'Presentation.Shell'
            arguments(:layout_call_argument) do
              parameter 'Presentation.Shell.Main'
              widgets(:div_container) do
                name 'templateContent'
                appearance do
                  css_class ''
                  style ''
                  set :design_properties, []
                  dynamic_classes ''
                end
                conditional_visibility_settings nil
                set :widgets, []
              end
            end
          end
          appearance do
            css_class ''
            style ''
            set :design_properties, []
            dynamic_classes ''
          end
          template_type(:regular_page_template_type) {}
          image_data Mxrb::Forms::BinaryAsset.read(preview, subtype: :generic)
        end

        building_block_document :Card do
          name 'Card'
          documentation 'Typed reusable building block'
          excluded false
          export_level :hidden
          canvas_width 800
          canvas_height 600
          display_name 'Card'
          documentation_url ''
          template_category 'General'
          template_category_weight 1
          widgets(:div_container) do
            name 'cardContent'
            appearance do
              css_class 'card-content'
              style ''
              set :design_properties, []
              dynamic_classes ''
            end
            conditional_visibility_settings nil
            set :widgets, []
          end
          platform :web
          image_data Mxrb::Forms::BinaryAsset.read(preview, subtype: :generic)
        end

        snippet_document :Summary do
          name 'Summary'
          documentation 'Typed reusable snippet'
          excluded false
          export_level :hidden
          canvas_width 800
          canvas_height 600
          widgets(:div_container) do
            name 'summaryContent'
            appearance do
              css_class 'summary-content'
              style ''
              set :design_properties, []
              dynamic_classes ''
            end
            conditional_visibility_settings nil
            set :widgets, []
          end
          type :web
          set :parameters, []
          set :variables, []
        end
      end

      navigation do
        profile :Responsive, home_page: 'Presentation.Home', app_title: 'Presentation Documents'
      end
    end
  end
end

PresentationDocumentsFixture.build(ARGV.fetch(0)) if $PROGRAM_NAME == __FILE__
# rubocop:enable Metrics/AbcSize, Metrics/BlockLength, Metrics/MethodLength, Metrics/ModuleLength
