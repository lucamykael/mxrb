# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'compiled modeler frontend' do
  let(:root) { Mxrb::WebUi.root }

  it 'ships local production entrypoints and every referenced asset' do
    %w[domain modeler uml].each do |entry|
      html = Mxrb::WebUi.page(entry)
      references = html.scan(%r{(?:src|href)="\./assets/([^"]+)"}).flatten

      expect(html).to include('<div id="root"></div>')
      expect(html).not_to match(%r{https?://})
      expect(references).not_to be_empty
      expect(references).to all(satisfy { File.file?(File.join(root, 'assets', _1)) })
    end
  end

  it 'keeps Node as a build-time dependency and embeds the bundle in the gem' do
    gem_files = Gem::Specification.load(File.expand_path('../mxrb.gemspec', __dir__)).files

    expect(gem_files).to include(
      'lib/mxrb/web_ui/domain.html', 'lib/mxrb/web_ui/modeler.html', 'lib/mxrb/web_ui/uml.html'
    )
    expect(gem_files).to include(a_string_starting_with('lib/mxrb/web_ui/assets/'))
    expect(Mxrb::WebUi.page('uml')).not_to include('cdn.jsdelivr.net', 'unpkg.com')
  end
end
