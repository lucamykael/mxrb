# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'Ruby application client constants' do
  it 'exposes typed current Ruby definitions without private or excluded constants and without MPR access' do
    Dir.mktmpdir do |directory|
      source = File.join(directory, 'Constants.mpr')
      Mxrb.define(source) do
        self.module :Settings do
          constant :Text, type: :string, value: 'initial', exposed_to_client: true
          constant :Count, type: :integer, value: 12, exposed_to_client: true
          constant :Amount, type: :decimal, value: '9007199254740993.125', exposed_to_client: true
          constant :Enabled, type: :boolean, value: false, exposed_to_client: true
          constant :Private, type: :string, value: 'private-value'
          constant :Excluded, type: :string, value: 'excluded-value', exposed_to_client: true, excluded: true
        end
      end
      root = File.join(directory, 'ruby')
      Mxrb::Exporter.new(source, root, mode: :ruby).export!
      allow(Mxrb::IO::MprFile).to receive(:open).and_raise('MPR access prohibited')
      application = Mxrb::RubyApp::Application.new(root)
      values = application.schema.fetch(:constants)
      expect(values).to eq('Settings.Text' => 'initial', 'Settings.Count' => 12,
                           'Settings.Amount' => { '__mxrb_decimal' => '9007199254740993.125' },
                           'Settings.Enabled' => false)
      expect(JSON.generate(application.schema)).not_to include('private-value', 'excluded-value')
      Mxrb::RubyApp::Registry.fetch(:constant, 'Settings.Text').default('edited')
      Mxrb::RubyApp::Registry.fetch(:constant, 'Settings.Enabled').default(true)
      expect(application.schema.fetch(:constants)).to include('Settings.Text' => 'edited', 'Settings.Enabled' => true)
      Mxrb::RubyApp::Registry.fetch(:constant, 'Settings.Text').exposed_to_client(false)
      expect(application.schema.fetch(:constants)).not_to have_key('Settings.Text')
      expect(JSON.generate(application.schema)).not_to include('initial', 'edited')
    ensure
      application&.close
      Mxrb::RubyApp::Registry.reset!
    end
  end
end
# rubocop:enable Metrics/BlockLength
