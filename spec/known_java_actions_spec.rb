# frozen_string_literal: true

require 'spec_helper'
require 'json'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::RubyApp::KnownJavaActions do
  after { Mxrb::RubyApp::Registry.reset! }

  it 'matches the recorded results of the pinned Java implementations, including Unicode and nulls' do
    cases = JSON.parse(File.read(File.join(__dir__, 'fixtures', 'feedback_action_cases.json')))
    cases.each do |item|
      method, parameter = item['kind'] == 'email' ? %i[validate_email EmailAddress] : %i[sanitize stringToSanitize]
      operation = -> { described_class.public_send(method, parameter.to_s => item.fetch('input')) }
      if item['error']
        expect(&operation).to raise_error(TypeError)
      else
        expect(operation.call&.to_s).to eq(item.fetch('expected')), item.inspect
      end
    end
  end

  it 'selects only byte-matched sources, accepting Windows newlines and leaving custom code explicit' do
    Dir.mktmpdir do |root|
      directory = File.join(root, 'javasource', 'feedbackmodule', 'actions')
      FileUtils.mkdir_p(directory)
      source = "// fixture\n"
      stub_const('Mxrb::RubyApp::KnownJavaActions::SOURCES',
                 'ValidateEmail' => [Digest::SHA256.hexdigest(source)], 'XSS_Sanitizer' => [])
      expect(described_class.registrations(root)).to eq('')
      File.binwrite(File.join(directory, 'ValidateEmail.java'), source.gsub("\n", "\r\n"))
      File.write(File.join(directory, 'XSS_Sanitizer.java'), '// customized')
      expect(described_class.registrations(root)).to eq('Mxrb::RubyApp::KnownJavaActions.register("ValidateEmail")')
      File.write(File.join(directory, 'ValidateEmail.java'), '// customized')
      expect(described_class.registrations(root)).to eq('')
    end
  end

  it 'registers qualified handlers and rejects unknown adapters' do
    described_class.register('ValidateEmail')
    described_class.register('XSS_Sanitizer')
    actions = Mxrb::RubyApp::Registry.java_custom_actions
    expect(actions.fetch('FeedbackModule.ValidateEmail').call('EmailAddress' => 'a@example.com')).to be(true)
    expect(actions.fetch('FeedbackModule.XSS_Sanitizer').call('stringToSanitize' => '<b>Ruby</b>')).to eq('Ruby')
    expect { described_class.register('Other') }.to raise_error(KeyError)
  end

  it 'exports a visible adapter registration that executes with all MPR access prohibited' do
    Dir.mktmpdir do |root|
      source = File.join(root, 'App.mpr')
      Mxrb.define(source) do
        self.module :FeedbackModule do
          java_action :ValidateEmail,
                      parameters: [{ name: 'EmailAddress', type: { kind: :basic, type: { kind: :string } } }],
                      return_type: { kind: :boolean }
          microflow :Check do
            parameter :Email, type: :String
            return_type :Boolean
            call_java 'FeedbackModule.ValidateEmail', as: :valid, pass: { EmailAddress: '$Email' }
            return_value '$valid'
          end
        end
      end
      java = File.join(root, 'javasource', 'feedbackmodule', 'actions', 'ValidateEmail.java')
      FileUtils.mkdir_p(File.dirname(java))
      File.write(java, '// fixture')
      stub_const('Mxrb::RubyApp::KnownJavaActions::SOURCES',
                 'ValidateEmail' => [Digest::SHA256.file(java).hexdigest])
      target = File.join(root, 'ruby')
      Mxrb::Exporter.new(source, target, mode: :ruby).export!
      expect(File.read(File.join(target, 'config',
                                 'adapters.rb'))).to include('KnownJavaActions.register("ValidateEmail")')
      allow(Mxrb::IO::MprFile).to receive(:open).and_raise('MPR prohibited')
      application = Mxrb::RubyApp::Application.new(target)
      expect(application.call_service('FeedbackModule.Check', { 'Email' => 'ruby@example.com' })).to be(true)
      expect(application.call_service('FeedbackModule.Check', { 'Email' => 'invalid' })).to be(false)
    ensure
      application&.close
    end
  end
end
# rubocop:enable Metrics/BlockLength
