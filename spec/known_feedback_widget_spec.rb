# frozen_string_literal: true

require 'spec_helper'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::RubyApp::KnownFeedbackWidget do
  it 'copies only verified project-owned ESM and its license into a portable Ruby app' do
    Dir.mktmpdir do |root|
      widgets = File.join(root, 'widgets')
      FileUtils.mkdir_p(widgets)
      expect(described_class.source(root)).to be_nil
      source = 'export default function Feedback() { return null; }'
      stub_const('Mxrb::RubyApp::KnownFeedbackWidget::HASHES', [Digest::SHA256.hexdigest(source)])
      File.write(File.join(widgets, '0-invalid.mpk'), 'not a zip')
      Zip::File.open(File.join(widgets, '1-other.mpk'), create: true) do |zip|
        zip.get_output_stream('unrelated.txt') { _1.write('other widget') }
      end
      Zip::File.open(File.join(widgets, '2-missing-license.mpk'), create: true) do |zip|
        zip.get_output_stream(described_class::ENTRY) { _1.write(source) }
      end
      Zip::File.open(File.join(widgets, '3-customized.mpk'), create: true) do |zip|
        zip.get_output_stream(described_class::ENTRY) { _1.write('// customized') }
        zip.get_output_stream('LICENSE') { _1.write('project-owned license') }
      end
      expect(described_class.source(root)).to be_nil
      Zip::File.open(File.join(widgets, '4-feedback.mpk'), create: true) do |zip|
        zip.get_output_stream(described_class::ENTRY) { _1.write(source) }
        zip.get_output_stream('LICENSE') { _1.write('project-owned license') }
        zip.get_output_stream('../not-exported.txt') { _1.write('ignored') }
      end
      expect(described_class.source(root)).to eq(bundle: source, license: 'project-owned license')
      # The isolated fixture does not need unrelated malformed packages in its model export.
      Dir.glob(File.join(widgets, '[0-3]-*.mpk')).each { File.delete(_1) }
      project = File.join(root, 'App.mpr')
      Mxrb.define(project) { self.module(:App) { entity(:Item) { string :Name } } }
      target = File.join(root, 'ruby')
      Mxrb::Exporter.new(project, target, mode: :ruby).export!
      generated = File.join(target, 'frontend', 'src', 'generated')
      expect(File.read(File.join(generated, 'bridge/vendor/feedback/Feedback.mjs'))).to eq(source)
      expect(File.read(File.join(generated, 'bridge/vendor/feedback/LICENSE'))).to eq('project-owned license')
      expect(File.read(File.join(generated, 'feedbackWidget.ts'))).to include('registerFeedbackWidget(Feedback)')
      expect(File.read(File.join(generated, 'bridge/vendor/feedback/Feedback.d.mts'))).to include('NativeFeedbackProps')
      expect(File.exist?(File.join(generated, 'bridge/vendor/not-exported.txt'))).to be(false)
    end
  end
end
# rubocop:enable Metrics/BlockLength
