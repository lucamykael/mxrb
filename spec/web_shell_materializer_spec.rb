# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Compiler::WebShellMaterializer do
  it 'renders Runtime placeholders and supplies self-contained login resources' do
    Dir.mktmpdir do |root|
      web = File.join(root, 'web')
      FileUtils.mkdir_p(web)
      File.write(File.join(web, 'theme.compiled.css'), 'body{}')
      index = File.join(web, 'index.html')
      File.write(
        index,
        '<head>{{unsupportedbrowser}}{{themecss}}{{appicons}}{{manifest}}</head>' \
        '<script src="x?{{cachebust}}"></script>'
      )
      File.write(File.join(web, 'login.html'), '<head>{{manifest}}</head>')

      expect(described_class.new(web, version: '11.12.1').materialize).to eq(2)
      rendered = File.read(index)
      token = Digest::SHA256.hexdigest('mxrb:web-shell:6:11.12.1')[0, 15].to_i(16).to_s
      expect(rendered).to include(
        'eval("async () => {}")',
        %(<link rel="stylesheet" href="theme.compiled.css?#{token}">),
        %(<link rel="manifest" href="manifest.webmanifest?#{token}"),
        %(<script src="x?#{token}"></script>),
        'data-mxrb-navigation-compat="6"', 'ui.openForm =', 'ui.openForm2('
      )
      expect(rendered).not_to match(/\{\{[^}]+\}\}/)
      expect(File.read(File.join(web, 'js/login_i18n.js'))).to include('window.i18nMap', 'http401')
      expect(File.read(File.join(web, 'lib/bootstrap/css/bootstrap.min.css')))
        .to include('.form-control', '.btn-primary')
      expect(File).to exist(File.join(web, 'dist/widgets.css'))
      expect(described_class.new(web, version: '11.12.1').send(
               :inject_navigation_compatibility, '<body>no head</body>'
             )).to eq('<body>no head</body>')
      expect(described_class.new(web, version: '11.12.1').materialize).to eq(0)
    end
  end

  it 'is a no-op when no web deployment exists' do
    expect(described_class.new('/path/that/does/not/exist', version: '7.17.0').materialize).to eq(0)
  end

  it 'omits the theme link when no compiled theme exists' do
    Dir.mktmpdir do |root|
      File.write(File.join(root, 'index.html'), '<head>{{themecss}}</head>')
      expect(described_class.new(root, version: '11.12.1').materialize).to eq(1)
      expect(File.read(File.join(root, 'index.html'))).to include(
        '<head>', 'data-mxrb-navigation-compat="6"', '</head>'
      )
    end
  end

  it 'versions React page imports in developer mode to prevent stale native bundles' do
    Dir.mktmpdir do |root|
      chunks = File.join(root, 'dist', 'chunks')
      FileUtils.mkdir_p(chunks)
      client = File.join(chunks, 'client.js')
      File.write(
        client,
        'let t=(0,A.g)().getConfig("isDevModeEnabled")?"":' \
        '`?${(0,A.g)().getConfig("cachebust")}`;import(`dist/pages/${e}.js${t}`)'
      )
      entry = File.join(root, 'dist', 'index.js')
      File.write(entry, 'import*as t from"./index.js";e.C(t),e(e.s=5237);')
      token = Digest::SHA256.hexdigest('mxrb:web-shell:6:11.12.1')[0, 15].to_i(16).to_s

      subject = described_class.new(root, version: '11.12.1')
      expect(subject.materialize).to eq(2)
      expect(File.read(client)).to include(
        "let t=`?#{token}${(0,A.g)().getConfig(\"cachebust\")}`",
        'import(`dist/pages/${e}.js${t}`)'
      )
      expect(File.read(entry)).to eq(
        %(import*as t from"./index.js?#{token}";e.C(t),e(e.s=5237);)
      )

      page = File.join(root, 'dist', 'pages', 'Demo.Home.js')
      FileUtils.mkdir_p(File.dirname(page))
      File.write(page, 'import*as r from"./Demo.Home.js";e.C(r),export const title="Home";')
      expect(subject.materialize_dynamic_imports).to eq(1)
      expect(File.read(page)).to include(%(from"./Demo.Home.js?#{token}"))
      expect(subject.materialize).to eq(0)
    end
  end

  it 'content-hashes a patched Runtime chunk and rewrites its imports' do
    Dir.mktmpdir do |root|
      chunks = File.join(root, 'dist', 'chunks')
      FileUtils.mkdir_p(chunks)
      old_stem = 'b5389ae7ff3d6547'
      client = File.join(chunks, "#{old_stem}.js")
      File.write(
        client,
        'let t=(0,A.g)().getConfig("isDevModeEnabled")?"":' \
        '`?${(0,A.g)().getConfig("cachebust")}`'
      )
      entry = File.join(root, 'dist', 'index.js')
      File.write(entry, %(import "./chunks/#{old_stem}.js"))

      materializer = described_class.new(root, version: '11.12.1')
      expect(materializer.materialize_dynamic_imports).to eq(1)
      new_stem = File.read(entry)[/[0-9a-f]{16}/]
      expect(new_stem).not_to eq(old_stem)
      expect(File).not_to exist(client)
      expect(File.read(File.join(chunks, "#{new_stem}.js")))
        .to include('let t=`?')

      stable_stem = '0123456789abcdef'
      stable = File.join(chunks, "#{stable_stem}.js")
      File.write(stable, 'before')
      allow(Digest::SHA256).to receive(:hexdigest).and_call_original
      allow(Digest::SHA256).to receive(:hexdigest).with('after').and_return(stable_stem)
      materializer.send(:write_versioned_chunk, stable, 'after')
      expect(File.read(stable)).to eq('after')
    end
  end
end
# rubocop:enable Metrics/BlockLength
