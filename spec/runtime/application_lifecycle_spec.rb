# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'Application lifecycle microflows' do
  around do |example|
    Dir.mktmpdir('mxrb-lifecycle-') do |root|
      @root = root
      @source = File.join(root, 'project', 'Life.mpr')
      build
      example.run
    ensure
      @application&.close
      Mxrb::RubyApp::Registry.reset!
    end
  end

  def build # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    Mxrb.define(@source) do
      mendix_version '11.12.1'
      self.module :Views do
        entity(:Entry) { string :Message }
        { Start: "'started'", Stop: "'stopped'" }.each do |name, message|
          microflow name do
            return_type :Boolean
            create_object 'Views.Entry', as: :entry, set: { Message: message }, commit: true
            return_value 'true'
          end
        end
        microflow :Refuse do
          return_type :Boolean
          return_value 'false'
        end
        microflow :Crash do
          return_type :Boolean
          call_java 'Views.Missing', as: :missing
          return_value 'true'
        end
      end
    end
    settings('AfterStartupMicroflow' => 'Views.Start', 'BeforeShutdownMicroflow' => 'Views.Stop')
  end

  def settings(values)
    mpr = Mxrb::IO::MprFile.open(@source, readonly: false)
    raw = mpr.all_units.find { mpr.parse_contents(_1)['$Type'] == 'Settings$ProjectSettings' }
    document = mpr.parse_contents(raw)
    items = Mxrb::IO::BsonCodec.parse_array(document['Settings'])[:items]
    items.find { _1['$Type'] == 'Settings$ModelSettings' }.merge!(values)
    mpr.update_unit(raw.fetch('UnitID'), document)
  ensure
    mpr&.close
  end

  def export
    target = File.join(@root, 'ruby')
    Mxrb::Exporter.new(@source, target, mode: :ruby).export!
    target
  end

  def start(target, after_startup: nil, process: {})
    manifest = File.join(target, '.mxrb', 'ruby-app.json')
    if after_startup
      data = JSON.parse(File.read(manifest))
      data['lifecycle']['after_startup'] = after_startup
      File.write(manifest, JSON.generate(data))
    end
    @application = Mxrb::RubyApp::Application.new(
      target, process: { 'MXRB_DATABASE_PATH' => File.join(@root, 'life.sqlite3') }.merge(process)
    )
  end

  def messages = @application.send(:bridge).store.retrieve('Views.Entry').map { _1.members['Message'] }.sort

  it 'runs the after-startup microflow once before scheduled events and the before-shutdown one on close' do
    target = export
    expect(JSON.parse(File.read(File.join(target, '.mxrb', 'ruby-app.json'))).fetch('lifecycle'))
      .to eq('after_startup' => 'Views.Start', 'before_shutdown' => 'Views.Stop')
    start(target)
    expect(messages).to eq([])
    @application.start_runtime
    @application.start_runtime
    expect(messages).to eq(%w[started])
    @application.close
    start(target)
    expect(messages).to eq(%w[started stopped])
  end

  it 'refuses to start when the after-startup microflow does not return true' do
    target = export
    start(target, after_startup: 'Views.Refuse')
    expect { @application.start_runtime }
      .to raise_error(Mxrb::StartupError, 'after-startup microflow Views.Refuse returned false')
    @application.close
    start(target, after_startup: 'Views.Crash')
    expect { @application.start_runtime }
      .to raise_error(Mxrb::StartupError,
                      /Views\.Crash failed: .*Views\.Missing is not registered.*MXRB_AFTER_STARTUP=skip/)
    @application.close
    start(target, process: { 'MXRB_AFTER_STARTUP' => 'skip' })
    @application.start_runtime
    expect(messages).to eq([])
  end

  it 'reports a failing before-shutdown microflow and still closes' do
    settings('AfterStartupMicroflow' => '', 'BeforeShutdownMicroflow' => 'Views.Crash')
    target = export
    expect(JSON.parse(File.read(File.join(target, '.mxrb', 'ruby-app.json'))).fetch('lifecycle'))
      .to eq('before_shutdown' => 'Views.Crash')
    start(target)
    @application.start_runtime
    expect { @application.close }.to output(/before-shutdown microflow Views\.Crash failed/).to_stderr
    @application = nil
  end

  it 'reads the lifecycle microflows from a project model' do
    project = Mxrb::Model::Project.open(@source)
    expect(Mxrb::Runtime::Lifecycle.settings(project))
      .to eq('after_startup' => 'Views.Start', 'before_shutdown' => 'Views.Stop')
  ensure
    project&.close
  end
end
# rubocop:enable Metrics/BlockLength
