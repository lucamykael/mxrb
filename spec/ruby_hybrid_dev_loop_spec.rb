# frozen_string_literal: true

require 'digest'
require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength, Metrics/MethodLength
RSpec.describe 'Ruby hybrid development loop' do
  def export_application(directory)
    source = File.join(directory, 'Shop.mpr')
    root = File.join(directory, 'shop_app')
    Mxrb.define(source) do
      mendix_version '11.12.1'
      self.module :Shop do
        entity(:Item) { string :Name }
        microflow(:Greeting) do
          return_type :String
          return_value '"native"'
        end
      end
    end
    Mxrb::Exporter.new(source, root, mode: :ruby).export!
    [root, source]
  end

  def replace_call(path, value)
    source = File.read(path)
    replacement = "    def call(**_arguments)\n      #{value.inspect}\n    end"
    source.sub!(/^    def call\(\*\*\w+\).*?^    end/m, replacement)
    File.write(path, source)
  end

  it 'reloads Ruby atomically, migrates additive model changes, and never writes the MPR' do
    Dir.mktmpdir('mxrb-hybrid-loop-') do |directory|
      root, = export_application(directory)
      runtime_mpr = Dir.glob(File.join(root, '.mxrb', 'runtime', '*.mpr')).fetch(0)
      mpr_digest = Digest::SHA256.file(runtime_mpr).hexdigest
      service = File.join(root, 'app', 'services', 'shop', 'greeting.rb')
      model = File.join(root, 'app', 'models', 'shop', 'item.rb')
      replace_call(service, 'ruby-v1')

      application = Mxrb::RubyApp::Application.new(root, reload: true)
      expect(application.invoke_service('Shop.Greeting').fetch(:result)).to eq('ruby-v1')
      created = application.create_record('Shop.Item', 'Name' => 'preserved')
      application.start_scheduler

      replace_call(service, 'ruby-v2')
      File.write(
        model,
        File.read(model).sub(
          '    clear_indexes!',
          "    attribute :description, type: :string, mendix_name: \"Description\", default: \"new\"\n" \
          '    clear_indexes!'
        )
      )
      expect(File.read(service)).to include('ruby-v2')
      expect(application.reload_if_changed!).to be(true)
      expect(Mxrb::RubyApp::Registry.fetch(:service, 'Shop.Greeting').new(application).call).to eq('ruby-v2')
      expect(application.invoke_service('Shop.Greeting').fetch(:result)).to eq('ruby-v2')
      expect(application.record('Shop.Item', created.fetch(:id)).fetch(:attributes)).to include(
        'Name' => 'preserved', 'Description' => 'new'
      )
      expect(application.reload_status).to include(enabled: true, state: 'reloaded', error: nil)

      valid_source = File.read(service)
      File.write(service, "#{valid_source}\nthis is not valid ruby(\n")
      expect { expect(application.reload_if_changed!).to be(false) }
        .to output(/keeping previous application/).to_stderr
      expect(application.invoke_service('Shop.Greeting').fetch(:result)).to eq('ruby-v2')
      expect(application.reload_status.fetch(:state)).to eq('error')
      expect(application.reload_status.fetch(:error)).to match(/SyntaxError/)

      File.write(service, valid_source.sub('ruby-v2', 'ruby-v3'))
      expect(application.reload_if_changed!).to be(true)
      expect(application.invoke_service('Shop.Greeting').fetch(:result)).to eq('ruby-v3')
      expect(application.reload_if_changed!).to be(false)
      expect(Digest::SHA256.file(runtime_mpr).hexdigest).to eq(mpr_digest)
      application.close
    end
  end

  it 'keeps reload disabled unless run or MXRB_RELOAD explicitly enables it' do
    Dir.mktmpdir('mxrb-hybrid-disabled-') do |directory|
      root, = export_application(directory)
      disabled = Mxrb::RubyApp::Application.new(root, process: {})
      expect(disabled.reload_status).to eq(enabled: false, state: 'ready', error: nil)
      expect(disabled.reload_if_changed!).to be(false)
      disabled.close

      enabled = Mxrb::RubyApp::Application.new(root, process: { 'MXRB_RELOAD' => 'yes' })
      expect(enabled.reload_status.fetch(:enabled)).to be(true)
      service = File.join(root, 'app', 'services', 'shop', 'greeting.rb')
      replace_call(service, 'loaded-before-bridge')
      expect(enabled.reload_if_changed!).to be(true)
      expect(Mxrb::RubyApp::Registry.fetch(:service, 'Shop.Greeting').new(enabled).call)
        .to eq('loaded-before-bridge')
      enabled.close
    end
  end

  it 'closes a staged runtime and restores the registry when scheduler startup fails' do
    Dir.mktmpdir('mxrb-hybrid-candidate-') do |directory|
      root, = export_application(directory)
      service = File.join(root, 'app', 'services', 'shop', 'greeting.rb')
      replace_call(service, 'stable')
      application = Mxrb::RubyApp::Application.new(root, reload: true)
      expect(application.invoke_service('Shop.Greeting').fetch(:result)).to eq('stable')
      application.start_scheduler

      candidate = double(close: nil)
      allow(candidate).to receive(:start_scheduler).and_raise(Mxrb::Error, 'scheduler failed')
      allow(application).to receive(:build_bridge).and_return(candidate)
      replace_call(service, 'candidate')
      expect { expect(application.reload_if_changed!).to be(false) }
        .to output(/scheduler failed/).to_stderr
      expect(candidate).to have_received(:close)
      expect(Mxrb::RubyApp::Registry.fetch(:service, 'Shop.Greeting').new(application).call)
        .to eq('stable')
      application.close
    end
  end
end
# rubocop:enable Metrics/BlockLength, Metrics/MethodLength
