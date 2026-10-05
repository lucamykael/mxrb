# frozen_string_literal: true

module Mxrb
  module RubyApp
    # Preserves layout arguments instead of flattening the page into their body.
    class PresentationProjection
      include Compiler::ModelValues

      def initialize(exporter) = (@exporter = exporter)

      def call(document)
        content = document['Content'] || document
        layout_call = content['LayoutCall'] || content['FormCall'] || {}
        name = layout_call['Layout'] || layout_call['Form']
        return widgets(content) if name.to_s.empty?

        [{ 'type' => 'layout', 'name' => name, 'options' => { 'layout' => name },
           'regions' => regions(layout_call) }]
      end

      private

      def widgets(document)
        page = Model::Page.allocate
        page.decode(document)
        page.widgets.map { @exporter.send(:widget_manifest, _1) }
      end

      def regions(layout_call)
        array(layout_call['Arguments']).to_h do |argument|
          parameter = (argument['Parameter'] || argument['Placeholder']).to_s.split('.').last
          [parameter, widgets('Widgets' => argument['Widgets'])]
        end
      end
    end
  end
end
