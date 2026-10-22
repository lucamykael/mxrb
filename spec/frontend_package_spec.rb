# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# The frontend packages the generated bridge needs, as the exporter declares
# them and the supervisor checks them before starting Vite.
# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::RubyApp::FrontendPackage do
  it 'reports the packages a package.json leaves undeclared and the runtime ones not installed' do
    Dir.mktmpdir do |directory|
      expect(described_class.undeclared(directory)).to include('react', 'vite')
      declared = described_class::DEPENDENCIES.except('decimal.js', 'plotly.js-dist-min')
      File.write(File.join(directory, 'package.json'),
                 JSON.generate('dependencies' => declared, 'devDependencies' => described_class::DEV_DEPENDENCIES))
      expect(described_class.undeclared(directory)).to eq(['decimal.js', 'plotly.js-dist-min'])
      File.write(File.join(directory, 'package.json'), 'not json')
      expect(described_class.undeclared(directory).length)
        .to eq(described_class::DEPENDENCIES.length + described_class::DEV_DEPENDENCIES.length)
      described_class::DEPENDENCIES.each_key { FileUtils.mkdir_p(File.join(directory, 'node_modules', _1)) }
      expect(described_class.uninstalled(directory)).to eq([])
      FileUtils.rm_rf(File.join(directory, 'node_modules', 'big.js'))
      expect(described_class.uninstalled(directory)).to eq(['big.js'])
    end
  end

  it 'keeps the npm files of a theme that was a package of its own out of the frontend' do
    Dir.mktmpdir do |root|
      theme = File.join(root, 'theme', 'web')
      FileUtils.mkdir_p([theme, File.join(root, 'themesource', 'legacy', 'web'),
                         File.join(root, 'themesource', 'legacy', 'public', 'node_modules', 'dep'),
                         File.join(root, 'theme', 'node_modules', 'sass')])
      File.write(File.join(theme, 'main.scss'), '$brand: red;')
      File.write(File.join(theme, 'package.json'), '{"name": "old-theme", "type": "commonjs"}')
      File.write(File.join(root, 'theme', 'package.json'), '{"name": "old-theme"}')
      File.write(File.join(root, 'theme', 'package-lock.json'), '{}')
      File.write(File.join(root, 'theme', 'node_modules', 'sass', 'index.js'), '')
      File.write(File.join(root, 'themesource', 'legacy', 'web', 'main.scss'), '')
      File.write(File.join(root, 'themesource', 'legacy', 'public', 'yarn.lock'), '')
      File.write(File.join(root, 'themesource', 'legacy', 'public', 'node_modules', 'dep', 'package.json'), '{}')
      File.write(File.join(root, 'themesource', 'legacy', 'public', 'favicon.ico'), 'icon')
      output = File.join(root, 'exported')
      exporter = Mxrb::RubyApp::Exporter.new(File.join(root, 'App.mpr'), output, mendix_sidecar: root)
      exporter.send(:copy_frontend_theme)
      copied = Dir.glob(File.join(output, 'frontend', '**', '*'), File::FNM_DOTMATCH)
                  .select { File.file?(_1) }.map { _1.delete_prefix("#{output}/frontend/") }
      expect(copied).to include('src/generated/platform/theme/web/main.scss',
                                'src/generated/platform/themesource/legacy/web/main.scss',
                                'src/generated/platform/theme-cache/web/favicon.ico', 'public/favicon.ico')
      expect(copied.grep(/package(-lock)?\.json|yarn\.lock|node_modules/)).to eq([])
    end
  end

  it 'stops the supervisor with the packages an older package.json or install lacks' do
    Dir.mktmpdir do |root|
      frontend = File.join(root, 'frontend')
      FileUtils.mkdir_p(File.join(frontend, 'node_modules'))
      supervisor = Mxrb::RubyApp::Supervisor.new(root)
      File.write(File.join(frontend, 'package.json'),
                 JSON.generate('dependencies' => { 'react' => '^19.2.8' }, 'devDependencies' => {}))
      expect { supervisor.send(:spawn_frontend) }
        .to raise_error(ArgumentError, /older than the generated bridge and lacks react-dom, .*; re-export/)
      File.write(File.join(frontend, 'package.json'),
                 JSON.generate('dependencies' => described_class::DEPENDENCIES,
                               'devDependencies' => described_class::DEV_DEPENDENCIES))
      expect { supervisor.send(:spawn_frontend) }
        .to raise_error(ArgumentError, /dependencies missing \(react, react-dom, .*\); run/)
      described_class::DEPENDENCIES.each_key { FileUtils.mkdir_p(File.join(frontend, 'node_modules', _1)) }
      expect(supervisor.send(:check_frontend_package, frontend)).to be_nil
    end
  end
end
# rubocop:enable Metrics/BlockLength
