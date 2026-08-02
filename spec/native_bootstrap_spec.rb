# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength, Metrics/MethodLength
RSpec.describe Mxrb::Compiler::DeploymentBootstrapper do
  around do |example|
    Dir.mktmpdir do |root|
      @root = root
      @mpr = File.join(root, 'Demo.mpr')
      Mxrb.define(@mpr) do
        mendix_version '11.12.1'
        self.module(:Demo) do
          entity :Record
          native_document :Assets, type: 'Images$ImageCollection', deep_structure: {
            'Images' => Mxrb::IO::BsonCodec.build_array([
                                                          {
                                                            '$Type' => 'Images$Image', 'Name' => 'Logo',
                                                            'Image' => BSON::Binary.new("\x89PNG\r\n\x1A\nimage".b)
                                                          }
                                                        ])
          }
        end
      end
      @version = File.join(root, '11.12.1')
      @templates = File.join(@version, 'modeler', 'runtemplates', 'deployment')
      prepare_templates
      prepare_assets
      example.run
    end
  end

  def prepare_templates
    %w[data log model native run tmp react-web].each do |name|
      FileUtils.mkdir_p(File.join(@templates, name))
    end
    File.write(File.join(@templates, 'run', 'component.xml'), '<component/>')
    FileUtils.mkdir_p(File.join(@templates, 'run', 'nested'))
    File.write(File.join(@templates, 'run', 'nested', 'child.xml'), '<child/>')
    File.write(File.join(@templates, 'native', 'metro.js.template'), '\\{{MxBuildNumber}\\}')
    File.write(File.join(@templates, 'react-web', 'index.html'), '<html/>')
    %w[rspack rollup].each do |name|
      File.write(
        File.join(@templates, 'react-web', "#{name}.config.mjs.template"),
        '{InstallDir:JsStringEncode}|{DeploymentDir:JsStringEncode}|{ProjectDir:HtmlAttributeEncode}|' \
        '{ProjectName:HtmlAttributeEncode}|{EnableWatchman:true|false}'
      )
    end
  end

  def prepare_assets
    {
      'userlib/app.jar' => 'user', 'vendorlib/vendor.jar' => 'vendor',
      'resources/app.txt' => 'resource', 'theme/web/favicon.ico' => 'icon',
      'theme-cache/web/theme.compiled.css' => 'css',
      'themesource/atlas_core/public/resources/switcher-toggle.png' => 'switcher',
      'themesource/atlas_core/public/resources/fonts/poppins/Poppins-Regular.ttf' => 'font'
    }.each do |relative, content|
      path = File.join(@root, relative)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
    end
  end

  it 'creates and then reuses a deployment from versioned templates and project assets' do
    deployment = File.join(@root, 'deployment')
    subject = described_class.new(@mpr, deployment:, mendix_home: @version)
    result = subject.prepare

    expect(result).to have_attributes(created: true, deployment:)
    expected = [
      File.join(deployment, 'model', 'model.mdp'),
      File.join(deployment, 'model', 'metadata.json'),
      File.join(deployment, 'model', 'bundles', 'project.jar'),
      File.join(deployment, 'model', 'lib', 'userlib', 'app.jar'),
      File.join(deployment, 'model', 'lib', 'userlib', 'vendor.jar'),
      File.join(deployment, 'web', 'theme.compiled.css'),
      File.join(deployment, 'web', 'resources', 'switcher-toggle.png'),
      File.join(deployment, 'web', 'resources', 'fonts', 'poppins', 'Poppins-Regular.ttf'),
      File.join(deployment, 'web', 'img', 'Demo$Assets$Logo.png')
    ]
    expect(expected).to all(satisfy { File.exist?(_1) })
    config = File.read(File.join(deployment, 'web', 'rspack.config.mjs'))
    expect(config).to include(@version, deployment, @root, 'Demo', 'false')
    expect(File.read(File.join(deployment, 'native', 'metro.js'))).to include('{mxrb-11.12.1}')

    FileUtils.rm_f(File.join(deployment, 'web', 'rspack.config.mjs'))
    FileUtils.rm_rf(File.join(deployment, 'web', 'img'))
    reused = described_class.new(
      @mpr, deployment:, mendix_home: File.join(@version, 'runtime')
    ).prepare
    expect(reused.created).to be false
    expect(File).to exist(File.join(deployment, 'web', 'rspack.config.mjs'))
    expect(File).to exist(File.join(deployment, 'web', 'img', 'Demo$Assets$Logo.png'))
  end

  it 'uses the default version home and fails clearly when templates are absent' do
    home = File.join(@root, 'home')
    default_version = File.join(home, '.local', 'share', 'mendix', '11.12.1')
    FileUtils.mkdir_p(File.dirname(default_version))
    FileUtils.cp_r(@version, File.dirname(default_version))
    allow(Dir).to receive(:home).and_return(home)
    default = described_class.new(@mpr, deployment: File.join(@root, 'default'))
    expect(default.prepare.created).to be true

    missing = described_class.new(
      @mpr, deployment: File.join(@root, 'missing'), mendix_home: File.join(@root, 'absent')
    )
    expect { missing.prepare }.to raise_error(Mxrb::CompilationError, /templates not found/)
  end

  it 'ignores absent template trees and preserves existing destination entries' do
    deployment = File.join(@root, 'deployment')
    subject = described_class.new(@mpr, deployment:, mendix_home: @version)
    destination = File.join(deployment, 'copy')
    FileUtils.mkdir_p(destination)
    File.write(File.join(destination, 'component.xml'), 'preserved')

    subject.send(:copy_tree, File.join(@templates, 'absent'), destination)
    subject.send(:copy_tree, File.join(@templates, 'run'), destination)

    expect(File.read(File.join(destination, 'component.xml'))).to eq('preserved')
    expect(File).to exist(File.join(destination, 'nested', 'child.xml'))
  end
end

RSpec.describe Mxrb::Compiler::SystemModelSeed do
  it 'loads the versioned System module and returns its project reference' do
    seed = described_class.for('11.12.1')
    reference = seed.module_reference
    expect(Mxrb::IO::BsonCodec.extract_id(reference['$ID'])).to eq(described_class::MODULE_ID)
    expect(reference['DomainModel']).to include('$Type' => 'DomainModels$DomainModel')
    expect(reference['AllDocuments']).not_to be_empty
  end

  it 'resolves audited major-version bands without crossing incompatible 7.x schemas' do
    expect(described_class.for('6.0.0').seed_version).to eq('6.10.8')
    expect(described_class.for('7.2.3').seed_version).to eq('7.5.0')
    expect(described_class.for('7.16.99').seed_version).to eq('7.5.0')
    expect(described_class.for('7.17.0').seed_version).to eq('7.17.0')
    expect(described_class.for('7.17.0-rc5').seed_version).to eq('7.17.0')
    expect(described_class.for('7.99.0').seed_version).to eq('7.17.0')
    expect(described_class.for('9.24.0').seed_version).to eq('9.6.1.29396')
    expect(described_class.for('11.99.0').seed_version).to eq('11.12.1')
  end

  it 'rejects missing, corrupt, and structurally incomplete seeds' do
    expect { described_class.for('0.0.0') }.to raise_error(Mxrb::CompilationError, /no audited native System/)
    expect { described_class.for('8.18.0') }.to raise_error(Mxrb::CompilationError, /supported families/)
    expect { described_class.for('invalid') }.to raise_error(Mxrb::CompilationError, /invalid Mendix version/)

    allow(File).to receive(:file?).and_call_original
    allow(File).to receive(:file?).with(/system-model-corrupt/).and_return(true)
    allow(File).to receive(:read).and_call_original
    allow(File).to receive(:read).with(/system-model-corrupt/).and_return('invalid')
    expect { described_class.for('corrupt') }.to raise_error(Mxrb::CompilationError, /invalid System/)

    expect { described_class.new(Mxrb::Compiler::ModelPackage.empty).module_reference }
      .to raise_error(Mxrb::CompilationError, /missing its module/)
  end
end

RSpec.describe Mxrb::Compiler::DeploymentMetadata do
  it 'uses safe defaults when a source has no project or translations' do
    source = instance_double(Mxrb::Compiler::SourceModel, version: '11.12.1', units: [], documents: [])
    allow(Mxrb::Runtime::Toolchain).to receive(:new).and_return(
      instance_double(Mxrb::Runtime::Toolchain, plan: instance_double(Mxrb::Runtime::Plan, java_version: '21'))
    )
    metadata = described_class.new('/tmp/Empty.mpr', source)
    expect(metadata.document).to include('ProjectID' => '', 'Languages' => [], 'JavaVersion' => 21)
    expect(metadata.dependencies).to include('appName' => 'Empty')
  end
end

RSpec.describe Mxrb::Compiler::SystemTextMaterializer do
  it 'compiles text references and provides a deterministic empty legacy fallback' do
    Dir.mktmpdir do |root|
      mpr = File.join(root, 'Text.mpr')
      deployment = File.join(root, 'deployment')
      Mxrb.define(mpr) do
        mendix_version '11.12.1'
        self.module(:Demo)
      end
      model = File.join(deployment, 'model', 'model.mdp')
      FileUtils.mkdir_p(File.dirname(model))
      Mxrb::Compiler::ModelPackage.empty.write(model)
      result = described_class.new(mpr, deployment:).materialize
      expect(result.texts).to be_positive

      source = instance_double(Mxrb::Compiler::SourceModel)
      allow(Mxrb::Compiler::SourceModel).to receive(:read).with(mpr).and_return(source)
      allow(source).to receive(:units_of).with('Texts$SystemTextCollection').and_return([])
      fallback = described_class.new(mpr, deployment:).materialize
      expect(fallback.texts).to eq(0)
      expect(Mxrb::Compiler::ModelPackage.read(model).types['Texts$SystemTextCollection']).to eq(1)
    end
  end
end

RSpec.describe Mxrb::Compiler::SystemQueueMaterializer do
  it 'adds built-in queues once' do
    Dir.mktmpdir do |root|
      path = File.join(root, 'model', 'model.mdp')
      FileUtils.mkdir_p(File.dirname(path))
      Mxrb::Compiler::ModelPackage.empty.write(path)
      allow(Mxrb::Compiler::SourceModel).to receive(:read).with('ignored.mpr').and_return(
        instance_double(Mxrb::Compiler::SourceModel, version: '11.12.1')
      )
      subject = described_class.new('ignored.mpr', deployment: root)
      expect(subject.materialize.queues).to eq(2)
      subject.materialize
      expect(Mxrb::Compiler::ModelPackage.read(path).types['Queues$Queue']).to eq(2)
    end
  end
end
# rubocop:enable Metrics/BlockLength, Metrics/MethodLength
