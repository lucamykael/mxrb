# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Lint/ConstantDefinitionInBlock, Metrics/AbcSize, Metrics/BlockLength, Metrics/MethodLength
RSpec.describe 'Entity lifecycle certification' do
  EVENTS = %i[before_commit after_commit before_delete after_delete].freeze

  it 'round-trips every native event and property with stable identities' do
    Dir.mktmpdir('mxrb-entity-lifecycle-') do |dir|
      current = File.join(dir, 'EntityLifecycle.mpr')
      build_source(current)
      baseline = lifecycle_snapshot(current)
      expect(baseline.map { _1.fetch(:event) }).to contain_exactly(*EVENTS)

      ruby_app = File.join(dir, 'ruby-app')
      ruby_rebuilt = File.join(dir, 'ruby-rebuilt.mpr')
      Mxrb::Exporter.new(current, ruby_app, mode: :ruby).export!
      ruby_source = File.read(File.join(ruby_app, 'app/models/app/audit.rb'))
      EVENTS.each { expect(ruby_source).to include("#{_1} microflow:") }
      Mxrb::RubyApp.compile(ruby_app, ruby_rebuilt)
      expect(Mxrb.compare(current, ruby_rebuilt)).to be_identical
      expect(lifecycle_snapshot(ruby_rebuilt)).to eq(baseline)

      2.times do |index|
        exported = File.join(dir, "ruby-#{index}")
        rebuilt = File.join(dir, "rebuilt-#{index}.mpr")
        Mxrb::Exporter.new(current, exported).export!
        source = File.read(File.join(exported, 'modules/App/domain/entities/audit.rb'))
        EVENTS.each { expect(source).to include("#{_1} microflow:") }
        expect(source).not_to include('native_document', 'deep_structure:', 'bson_binary(')

        generate(exported, rebuilt)
        expect(Mxrb.validate(rebuilt)).to be_valid
        expect(Mxrb.compare(current, rebuilt)).to be_identical
        expect(lifecycle_snapshot(rebuilt)).to eq(baseline)
        current = rebuilt
      end
    end
  end

  def build_source(path)
    Mxrb.define(path) do
      mendix_version '11.12.1'
      self.module :App do
        page(:Home) { title 'Entity lifecycle' }
        entity(:Audit) do
          before_commit microflow: 'App.BeforeCommit', pass_event_object: false,
                        raise_error_on_false: true
          after_commit microflow: 'App.AfterCommit', pass_event_object: false,
                       raise_error_on_false: false
          before_delete microflow: 'App.BeforeDelete', pass_event_object: false,
                        raise_error_on_false: false
          after_delete microflow: 'App.AfterDelete', pass_event_object: false,
                       raise_error_on_false: true
        end
        microflow(:BeforeCommit) do
          return_type :Boolean
          return_value 'true'
        end
        microflow(:BeforeDelete) do
          return_type :Boolean
          return_value 'true'
        end
        microflow(:AfterCommit) { log_message 'after commit' }
        microflow(:AfterDelete) { log_message 'after delete' }
      end
      navigation do
        profile :Responsive, home_page: 'App.Home', app_title: 'Entity lifecycle'
      end
    end
  end

  def lifecycle_snapshot(path)
    Mxrb.open(path) do |project|
      entity = project.entities.find { _1.name == 'Audit' }
      lifecycle = entity.lifecycle.map do |event|
        event.merge(id: event.fetch(:id).to_s)
      end
      lifecycle.sort_by { _1.fetch(:event).to_s }
    end
  end

  def generate(exported, rebuilt)
    previous = ENV['MXRB_OUTPUT_PATH']
    ENV['MXRB_OUTPUT_PATH'] = rebuilt
    load File.join(exported, 'project.rb')
  ensure
    previous ? ENV['MXRB_OUTPUT_PATH'] = previous : ENV.delete('MXRB_OUTPUT_PATH')
  end
end
# rubocop:enable Lint/ConstantDefinitionInBlock, Metrics/AbcSize, Metrics/BlockLength, Metrics/MethodLength
