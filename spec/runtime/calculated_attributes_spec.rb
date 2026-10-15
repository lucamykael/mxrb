# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'calculated attributes' do
  let(:fixture) { 'spec/fixtures/native_calculated_attributes' }
  let(:expected) { JSON.parse(File.read(File.join(fixture, 'expected.json'))).fetch('results') }

  around do |example|
    Dir.mktmpdir do |directory|
      previous = ENV.fetch('MXRB_OUTPUT_PATH', nil)
      ENV['MXRB_OUTPUT_PATH'] = File.join(directory, 'Calculated.mpr')
      load File.join(fixture, 'project.rb')
      @project = Mxrb.open(ENV.fetch('MXRB_OUTPUT_PATH'))
      example.run
    ensure
      ENV['MXRB_OUTPUT_PATH'] = previous
      @project&.close
    end
  end

  def logged(interpreter)
    interpreter.instance_variable_get(:@log).to_h do |line|
      name, values = line.delete_prefix('ORACLE ').split('=', 2)
      [name, values.delete_suffix(',').split(',')]
    end
  end

  it 'runs the microflow on each read, as the native Mendix 11.12.1 Runtime' do
    interpreter = Mxrb::Runtime::Native::Interpreter.new(@project)
    expect(interpreter.call('Views.RunAll')).to be(true)
    expect(logged(interpreter)).to eq(expected)
  end

  it 'reads the microflow back from the model' do
    person = @project.modules.find { _1.name == 'Views' }.entities.find { _1.name == 'Person' }
    full, fixed, first = %w[FullName Fixed First].map { |name| person.attributes.find { _1.name == name } }
    expect([full.calculated, full.pass_entity]).to eq(['Views.CalcFullName', true])
    expect([fixed.calculated, fixed.pass_entity]).to eq(['Views.CalcFixed', false])
    expect([first.calculated, first.pass_entity]).to eq([nil, nil])
  end

  it 'computes an attribute a generalization calculates' do
    ENV['MXRB_OUTPUT_PATH'] = File.join(File.dirname(ENV.fetch('MXRB_OUTPUT_PATH')), 'Inherited.mpr')
    Mxrb.define('Inherited.mpr') do
      mendix_version '11.12.1'
      self.module :Shop do
        entity(:Base) { string :Label, calculated: 'Shop.CalcLabel', pass_entity: false }
        entity(:Item) { generalizes 'Shop.Base' }
        microflow :CalcLabel do
          return_type :String
          return_value "'label'"
        end
      end
    end
    Mxrb.open(Mxrb.last_defined_path) do |project|
      interpreter = Mxrb::Runtime::Native::Interpreter.new(project)
      item = Mxrb::Runtime::Native::ObjectValue.new(entity: 'Shop.Item', id: '1', members: {})
      expect(interpreter.calculated_members(item)).to eq('Label' => 'label')
    end
  end

  it 'fails when the microflow is missing' do
    interpreter = Mxrb::Runtime::Native::Interpreter.new(@project)
    interpreter.instance_variable_get(:@flows).delete('Views.CalcFixed')
    person = Mxrb::Runtime::Native::ObjectValue.new(entity: 'Views.Person', id: '1', members: {})
    expect { interpreter.send(:calculated_value, person, 'Fixed') }
      .to raise_error(Mxrb::NativeRuntimeError, /needs microflow Views.CalcFixed/)
  end
end

RSpec.describe 'calculated attributes in a Ruby application' do
  after { Mxrb::RubyApp::Registry.reset! }

  it 'exports the microflow and runs it on each read' do
    Dir.mktmpdir('mxrb-calculated-') do |directory|
      source = File.join(directory, 'Source.mpr')
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('MXRB_OUTPUT_PATH').and_return(source)
      load File.expand_path('../fixtures/native_calculated_attributes/project.rb', __dir__)
      target = File.join(directory, 'ruby')
      Mxrb::Exporter.new(source, target, mode: :ruby).export!
      record = Dir.glob(File.join(target, '**', 'person.rb')).map { File.read(_1) }.join
      expect(record).to include('calculated: "Views.CalcFullName"', 'calculated: "Views.CalcFixed", pass_entity: false')
      application = Mxrb::RubyApp::Application.new(target)
      interpreter = application.send(:bridge).interpreter
      expect(interpreter.call('Views.RunAll')).to be(true)
      expected = JSON.parse(File.read(File.expand_path('../fixtures/native_calculated_attributes/expected.json',
                                                       __dir__))).fetch('results')
      logged = interpreter.instance_variable_get(:@log).to_h do |line|
        name, values = line.delete_prefix('ORACLE ').split('=', 2)
        [name, values.delete_suffix(',').split(',')]
      end
      expect(logged).to eq(expected)
    ensure
      application&.close
    end
  end
end

RSpec.describe 'calculated attributes synchronized from Ruby' do
  after { Mxrb::RubyApp::Registry.reset! }

  def values(path)
    Mxrb.open(path) do |project|
      person = project.modules.find { _1.name == 'Views' }.entities.find { _1.name == 'Person' }
      person.attributes.to_h { [_1.name, [_1.raw_value_doc['$Type'], _1.calculated, _1.pass_entity]] }
    end
  end

  it 'keeps, changes and removes the microflow of an attribute' do
    Dir.mktmpdir('mxrb-calculated-sync-') do |directory|
      source = File.join(directory, 'Source.mpr')
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('MXRB_OUTPUT_PATH').and_return(source)
      load File.expand_path('../fixtures/native_calculated_attributes/project.rb', __dir__)
      exported = File.join(directory, 'ruby')
      Mxrb::Exporter.new(source, exported, mode: :ruby).export!(parallel: false)
      target = File.join(directory, 'Target.mpr')
      FileUtils.cp(source, target)
      Mxrb::RubyApp::Synchronizer.new(exported, target).synchronize!
      expect(values(target)).to eq(values(source))

      person = Dir.glob(File.join(exported, '**', 'person.rb')).first
      edited = File.read(person).sub(', calculated: "Views.CalcFullName"', '')
                   .sub('calculated: "Views.CalcFixed", pass_entity: false', 'calculated: "Views.CalcFullName"')
                   .sub(/(mendix_name: "First".*enumeration: nil)/,
                        '\\1, calculated: "Views.CalcFixed", pass_entity: false')
      File.write(person, edited)
      Mxrb::RubyApp::Registry.reset!
      Mxrb::RubyApp::Synchronizer.new(exported, target).synchronize!
      expect(values(target)).to include(
        'FullName' => ['DomainModels$StoredValue', nil, nil],
        'Fixed' => ['DomainModels$CalculatedValue', 'Views.CalcFullName', true],
        'First' => ['DomainModels$CalculatedValue', 'Views.CalcFixed', false]
      )
    end
  end
end

RSpec.describe 'calculated attributes sent to the client' do
  after { Mxrb::RubyApp::Registry.reset! }

  it 'computes them for the user and keeps the effects of the request' do
    Dir.mktmpdir('mxrb-calculated-client-') do |directory|
      source = File.join(directory, 'Source.mpr')
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('MXRB_OUTPUT_PATH').and_return(source)
      load File.expand_path('../fixtures/native_calculated_attributes/project.rb', __dir__)
      target = File.join(directory, 'ruby')
      Mxrb::Exporter.new(source, target, mode: :ruby).export!(parallel: false)
      application = Mxrb::RubyApp::Application.new(target)
      interpreter = application.send(:bridge).interpreter
      counter = interpreter.store.create('Views.Counter')
      counter.members['Calls'] = 0
      interpreter.store.commit(counter)
      person = Mxrb::Runtime::Native::ObjectValue.new(entity: 'Views.Person', id: '1',
                                                      members: { 'First' => 'Ada', 'Last' => 'Byron' })
      effect = { type: 'show_message', message: 'kept' }
      interpreter.effects << effect
      attributes = application.send(:serialize, person).fetch(:attributes)
      expect(attributes).to include('FullName' => 'Ada Byron', 'Fixed' => 'fixed')
      expect(interpreter.effects).to start_with(effect)
      expect(interpreter.calculated_members(counter)).to eq({})
      java = interpreter.send(:java_action_context)
      expect([java.value(person, 'FullName'), java.value(person, 'First')]).to eq(['Ada Byron', 'Ada'])
    ensure
      application&.close
    end
  end
end
# rubocop:enable Metrics/BlockLength
