# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'Constants in microflow expressions' do
  around do |example|
    Dir.mktmpdir('mxrb-constants-') do |root|
      @root = root
      @source = File.join(root, 'project', 'Consts.mpr')
      Mxrb.define(@source) do
        mendix_version '11.12.1'
        self.module :Config do
          constant :Skip, type: :boolean, value: 'True'
          constant :Limit, type: :integer, value: '7'
          constant :Rate, type: :decimal, value: '1.50'
          constant :Since, type: :date_time, value: '2024-02-03T04:05:06'
          constant :Label, type: :string, value: 'shown', exposed_to_client: true
          constant :Blank, type: :string, value: ''
          microflow :Describe do
            return_type :String
            return_value "if @Config.Skip then @Config.Label + ':' + toString(@Config.Limit + 1) else 'none'"
          end
        end
      end
      example.run
    ensure
      @application&.close
      Mxrb::RubyApp::Registry.reset!
    end
  end

  def expression(constants) = Mxrb::Runtime::Native::Expression.new(constants: ->(name) { constants.value(name) })

  it 'reads typed defaults and deployment overrides from the model' do
    project = Mxrb::Model::Project.open(@source)
    constants = Mxrb::Runtime::Constants.new(project, environment: { 'MX_Config_Limit' => '9' })
    values = %w[Skip Limit Rate Since Label Blank].map { constants.value("Config.#{_1}") }
    expect(values).to eq([true, 9, BigDecimal('1.50'), Time.utc(2024, 2, 3, 4, 5, 6), 'shown', ''])
    expect(expression(constants).evaluate('@Config.Limit * 2', {})).to eq(18)
    expect do
      constants.value('Config.Missing')
    end.to raise_error(Mxrb::NativeRuntimeError, 'unknown constant @Config.Missing')
    expect { constants.value('Nowhere.Thing') }.to raise_error(Mxrb::NativeRuntimeError, /unknown constant/)
    runtime = Mxrb::Runtime::Native::Interpreter.new(project)
    expect(runtime.call('Config.Describe')).to eq('shown:8')
    expect { Mxrb::Runtime::Native::Expression.new.evaluate('@Config.Skip', {}) }
      .to raise_error(Mxrb::NativeRuntimeError, /constant @Config\.Skip is not available here/)
  ensure
    project&.close
  end

  it 'reads private defaults from the local sidecar of an exported application' do
    target = File.join(@root, 'ruby')
    Mxrb::Exporter.new(@source, target, mode: :ruby).export!
    expect(File.read(File.join(target, 'app', 'constants', 'config', 'skip.rb'))).to include('preserve_default!')
    process = { 'MXRB_DATABASE_PATH' => ':memory:', 'MX_Config_Rate' => '2.25' }
    @application = Mxrb::RubyApp::Application.new(target, process:)
    interpreter = @application.send(:bridge).interpreter
    expect(interpreter.call('Config.Describe')).to eq('shown:8')
    evaluate = ->(text) { interpreter.instance_variable_get(:@expression).evaluate(text, {}) }
    expect(evaluate.call('@Config.Rate')).to eq(BigDecimal('2.25'))
    expect(evaluate.call('@Config.Blank')).to eq('')
    @application.close

    sidecar = Dir.glob(File.join(target, '.mxrb', 'mendix', 'modules', 'Config', 'domain', 'constants', 'limit.rb'))
    File.write(sidecar.first, File.read(sidecar.first).sub(/value: "7",\n/, ''))
    @application = Mxrb::RubyApp::Application.new(target, process: { 'MXRB_DATABASE_PATH' => ':memory:' })
    expect { @application.send(:bridge).interpreter.call('Config.Describe') }
      .to raise_error(Mxrb::NativeRuntimeError, 'constant @Config.Limit has no value; set MX_Config_Limit')
    project = @application.send(:bridge).project
    expect(project.constant_definition('Config.Since')[:default]).to eq('2024-02-03T04:05:06')
    expect(project.constant_definition('Config.Label')).to eq(type: :string, default: 'shown')
    expect(project.constant_definition('Config.Nope')).to be_nil
    File.delete(File.join(File.dirname(sidecar.first), 'blank.rb'))
    File.write(File.join(File.dirname(sidecar.first), 'notes.rb'), "# no constant here\n")
    expect(project.constant_definition('Config.Blank')).to eq(type: :string, default: nil)
    expect([Mxrb::Runtime::Constants.cast(nil, :string), Mxrb::Runtime::Constants.cast('', :integer),
            Mxrb::Runtime::Constants.cast('', :decimal), Mxrb::Runtime::Constants.cast('', :date_time)])
      .to eq([nil, nil, nil, nil])
  end
end
# rubocop:enable Metrics/BlockLength
