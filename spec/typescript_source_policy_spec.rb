# frozen_string_literal: true

require 'spec_helper'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'TypeScript source policy' do
  it 'keeps editable frontend sources in TypeScript' do
    root = File.expand_path('..', __dir__)
    source_roots = %w[bin exe frontend lib marketplace script spec templates]
    javascript_sources = source_roots.flat_map do |directory|
      Dir.glob(File.join(root, directory, '**', '*.{js,jsx}'))
    end
    javascript_sources.reject! do |path|
      relative = path.delete_prefix("#{root}/")
      relative.start_with?(
        'frontend/modeler/node_modules/',
        'lib/mxrb/web_ui/assets/'
      )
    end

    expect(javascript_sources).to(
      be_empty,
      "editable JavaScript sources must be migrated to .ts/.tsx: #{javascript_sources.join(', ')}"
    )
  end

  it 'treats embedded JavaScript as compiled modeler output' do
    root = File.expand_path('..', __dir__)
    bundles = Dir.glob(File.join(root, 'lib/mxrb/web_ui/assets/*.js'))

    expect(bundles).not_to be_empty
    expect(File.read(File.join(root, 'frontend/modeler/package.json'))).to include('"build":')
    expect(File.read(File.join(root, 'frontend/modeler/vite.config.ts')))
      .to include("outDir: '../../lib/mxrb/web_ui'")
  end
end
# rubocop:enable Metrics/BlockLength
