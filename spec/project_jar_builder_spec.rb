# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'zip'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Compiler::ProjectJarBuilder do
  around do |example|
    Dir.mktmpdir do |dir|
      @root = dir
      @mpr = File.join(dir, 'Demo.mpr')
      Mxrb.define(@mpr) do
        mendix_version '11.12.1'
        self.module(:Demo) { entity :Record }
      end
      @deployment = File.join(dir, 'deployment')
      @runtime = File.join(dir, 'mendix', 'runtime')
      @java = File.join(dir, 'jdk')
      FileUtils.mkdir_p(File.join(@deployment, 'run'))
      FileUtils.mkdir_p(File.join(@runtime, 'bundles'))
      FileUtils.mkdir_p(File.join(@java, 'bin'))
      %w[java javac].each do |name|
        path = File.join(@java, 'bin', name)
        File.write(path, "#!/bin/sh\n")
        FileUtils.chmod(0o755, path)
      end
      example.run
    end
  end

  def builder
    described_class.new(
      @mpr, deployment: @deployment, mendix_home: File.dirname(@runtime), java_home: @java
    )
  end

  it 'compiles sources and packages classes, OSGi metadata, and user resources' do
    source = File.join(@root, 'javasource', 'demo', 'Hello.java')
    resource = File.join(@root, 'userlib', 'settings.properties')
    FileUtils.mkdir_p(File.dirname(source))
    FileUtils.mkdir_p(File.dirname(resource))
    File.write(source, 'package demo; class Hello {}')
    File.write(resource, 'enabled=true')
    File.write(File.join(@deployment, 'run', 'component.xml'), '<component/>')
    File.write(File.join(@runtime, 'bundles', 'runtime.jar'), 'jar')
    File.write(File.join(@root, 'userlib', 'library.jar'), 'jar')

    allow(Open3).to receive(:capture2e) do |_javac, argument|
      arguments = File.readlines(argument.delete_prefix('@'), chomp: true).map do |line|
        line.delete_prefix('"').delete_suffix('"')
      end
      classes = arguments.fetch(arguments.index('-d') + 1)
      output = File.join(classes, 'demo', 'Hello.class')
      FileUtils.mkdir_p(File.dirname(output))
      File.binwrite(output, 'bytecode')
      ['', instance_double(Process::Status, success?: true)]
    end

    result = builder.build
    expect(result.to_h).to include(sources: 1, classes: 1, classpath_entries: 2)
    Zip::File.open(result.path) do |archive|
      expect(archive.glob('**/*').map(&:name)).to include(
        'META-INF/MANIFEST.MF', 'demo/Hello.class',
        'OSGI-INF/component.xml', 'settings.properties'
      )
      expect(archive.read('META-INF/MANIFEST.MF')).to include(
        "Bundle-Name: demo\r\n", "Bundle-SymbolicName: project\r\n"
      )
    end
  end

  it 'writes an empty bundle and reports missing or failed Java compilation clearly' do
    empty = builder.build
    expect(empty.sources).to eq(0)
    expect(empty.classes).to eq(0)

    FileUtils.rm(File.join(@java, 'bin', 'javac'))
    expect { builder.build }.to raise_error(Mxrb::CompilationError, /Java 21 JDK not found/)

    File.write(File.join(@java, 'bin', 'javac'), "#!/bin/sh\n")
    FileUtils.chmod(0o755, File.join(@java, 'bin', 'javac'))
    source = File.join(@root, 'javasource', 'Broken.java')
    FileUtils.mkdir_p(File.dirname(source))
    File.write(source, 'broken')
    allow(Open3).to receive(:capture2e).and_return(
      ['compiler diagnostic', instance_double(Process::Status, success?: false)]
    )
    expect { builder.build }.to raise_error(Mxrb::CompilationError, /compiler diagnostic/)
  end

  it 'accepts a Runtime directory directly and de-duplicates classpath jars' do
    duplicate = File.join(@runtime, 'bundles', 'same.jar')
    File.write(duplicate, 'jar')
    direct = described_class.new(
      @mpr, deployment: @deployment, mendix_home: @runtime, java_home: @java
    )
    expect(direct.build.classpath_entries).to eq(1)
  end

  it 'generates only Java proxies referenced by custom project sources' do
    Mxrb.define(@mpr) do
      mendix_version '11.12.1'
      self.module(:Demo) do
        enumeration(:State) do
          value :Open
          value :Closed
        end
        constant :Limit, type: :integer, value: 10
        entity(:Record) do
          string :Name
          enum :State, enumeration: 'Demo.State'
        end
        entity :Unused
      end
    end
    source = File.join(@root, 'javasource', 'demo', 'UseProxy.java')
    FileUtils.mkdir_p(File.dirname(source))
    File.write(source, <<~JAVA)
      package demo;
      class UseProxy {
        demo.proxies.Record record;
        demo.proxies.State state;
        long limit = demo.proxies.constants.Constants.getLimit();
      }
    JAVA
    allow(Open3).to receive(:capture2e).and_return(
      ['', instance_double(Process::Status, success?: true)]
    )

    expect(builder.build.sources).to eq(4)
    expect(File.read(File.join(@root, 'javasource/demo/proxies/Record.java')))
      .to include('class Record', 'getName', 'demo.proxies.State')
    expect(File).not_to exist(File.join(@root, 'javasource/demo/proxies/Unused.java'))
    expect(File.read(File.join(@root, 'javasource/demo/proxies/constants/Constants.java')))
      .to include('getLimit')
  end

  it 'renders inherited and association proxy contracts without overwriting user files' do
    generator = Mxrb::Compiler::JavaProxyGenerator.allocate
    parent = {
      '$ID' => 'parent', 'Name' => 'Parent', 'Attributes' => [2],
      'MaybeGeneralization' => { 'Generalization' => '' }
    }
    child = {
      '$ID' => 'child', 'Name' => 'Child', 'Attributes' => [2],
      'MaybeGeneralization' => { 'Generalization' => 'Demo.Parent' }
    }
    association = {
      'Name' => 'Parent_Children', 'Type' => 'ReferenceSet',
      'ParentPointer' => 'parent', 'ChildPointer' => 'child'
    }
    unit = Mxrb::Compiler::SourceModel::Unit.new(
      id: 'domain', container_id: 'module', containment: 'DomainModel', module_name: 'Demo',
      document: { '$Type' => 'DomainModels$DomainModel', 'Entities' => [2, parent, child],
                  'Associations' => [2, association] }
    )
    entities = { 'Demo.Parent' => [unit, parent], 'Demo.Child' => [unit, child] }
    generator.instance_variable_set(:@entities, entities)
    generator.instance_variable_set(:@project_root, @root)

    expect(generator.send(:requested_entities, 'demo.proxies.Child')).to contain_exactly('Demo.Child', 'Demo.Parent')
    expect(generator.send(:entity_source, unit, child)).to include('extends demo.proxies.Parent', 'super(context')
    expect(generator.send(:association_methods, unit, association)).to include('java.util.List<demo.proxies.Child>')
    expect(generator.send(:association_methods, unit, association.merge('ChildPointer' => 'missing')))
      .to include('IEntityProxy')
    expect(generator.send(:association_methods, unit, association.merge('Type' => 'Reference'))).to eq('')
    expect(generator.send(:identifier, Struct.new(:data).new('binary'))).to eq('binary')
    expect(generator.send(:attribute_java_type, unit, '$Type' => 'DomainModels$EnumerationAttributeType',
                                                      'Enumeration' => 'State'))
      .to eq('demo.proxies.State')

    path = File.join(@root, 'javasource', 'existing.java')
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, 'user owned')
    expect(generator.send(:write_missing, path, 'generated')).to be(false)
    expect(File.read(path)).to eq('user owned')
  end
end
# rubocop:enable Metrics/BlockLength

RSpec.describe Mxrb::Runtime::JavaLocator do
  it 'prefers configured homes and rejects homes without Java' do
    Dir.mktmpdir do |dir|
      allow(ENV).to receive(:[]).with('MXRB_JAVA_HOME').and_return(nil)
      allow(ENV).to receive(:[]).with('JAVA_HOME').and_return(nil)
      missing = File.join(dir, 'missing')
      valid = File.join(dir, 'valid')
      FileUtils.mkdir_p(File.join(valid, 'bin'))
      File.write(File.join(valid, 'bin', 'java'), '')
      FileUtils.chmod(0o755, File.join(valid, 'bin', 'java'))
      allow(described_class).to receive(:installed).and_return([valid])

      expect(described_class.resolve('21', configured: missing)).to eq(valid)
      expect(described_class.resolve('21', configured: valid)).to eq(valid)
    end
  end

  it 'discovers only matching asdf and mise installations' do
    allow(Dir).to receive(:home).and_return(@root || Dir.home)
    expect(described_class.installed('987654')).to eq([])
  end
end
