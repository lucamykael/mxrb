# frozen_string_literal: true

module Mxrb
  module RubyApp
    # Preserves layout arguments instead of flattening the page into their body.
    class PresentationProjection
      include Compiler::ModelValues

      def initialize(exporter) = (@exporter = exporter)

      # +name+ identifies the document whose design declarations the projected
      # widgets take over from the recorded design classes.
      def call(document, name:)
        designs = DesignDeclarations.declared(document)
        projected = DesignDeclarations.inject(project(document), designs)
        @exporter.send(:record_declared_designs, name, DesignDeclarations.injected_keys(projected, designs))
        projected
      end

      private

      def project(document)
        content = document['Content'] || document
        return native_layout(content) if content['$Type'] == 'Forms$NativeLayoutContent'

        layout_call = content['LayoutCall'] || content['FormCall'] || {}
        name = layout_call['Layout'] || layout_call['Form']
        return widgets(content) if name.to_s.empty?

        [{ 'type' => 'layout', 'name' => name, 'options' => { 'layout' => name },
           'regions' => regions(layout_call) }]
      end

      # A native layout keeps its header placeholder, its sidebar and whether
      # the profile's bottom bar shows, which the phone shell renders.
      def native_layout(content)
        header = content['RightHeaderPlaceholder']
        regions = { 'content' => widgets(content) }
        regions['header'] = widgets('Widgets' => [3, header]) if header.is_a?(Hash)
        regions['sidebar'] = widgets('Widgets' => content['SidebarWidgets']) if content['Sidebar'] == true
        options = {
          'layout_type' => content.fetch('LayoutType', 'Default').to_s.downcase,
          'show_bottom_bar' => content['ShowBottomBar'] == true, 'sidebar' => content['Sidebar'] == true
        }
        [{ 'type' => 'native_layout', 'name' => 'NativeLayout', 'options' => options, 'regions' => regions }]
      end

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
