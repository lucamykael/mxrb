# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

RSpec.describe Mxrb::Compiler::WebShellMaterializer do
  it 'renders Runtime placeholders and supplies self-contained login resources' do
    Dir.mktmpdir do |root|
      web = File.join(root, 'web')
      FileUtils.mkdir_p(web)
      index = File.join(web, 'login.html')
      File.write(index, '<head>{{appicons}}</head><script src="x?{{cachebust}}"></script>')

      expect(described_class.new(web, version: '11.12.1').materialize).to eq(1)
      expect(File.read(index)).to eq('<head></head><script src="x?mxrb-11.12.1"></script>')
      expect(File.read(File.join(web, 'js/login_i18n.js'))).to include('window.i18nMap', 'http401')
      expect(File.read(File.join(web, 'lib/bootstrap/css/bootstrap.min.css')))
        .to include('.form-control', '.btn-primary')
      expect(described_class.new(web, version: '11.12.1').materialize).to eq(0)
    end
  end

  it 'is a no-op when no web deployment exists' do
    expect(described_class.new('/path/that/does/not/exist', version: '7.17.0').materialize).to eq(0)
  end
end
