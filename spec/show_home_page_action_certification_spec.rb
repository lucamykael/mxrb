# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/AbcSize, Metrics/BlockLength, Metrics/MethodLength
RSpec.describe 'Show home page action certification' do
  after { Mxrb::RubyApp::Registry.reset! }

  it 'authors and round-trips the Mendix 11 action with stable native identities' do
    Dir.mktmpdir('mxrb-show-home-page-') do |dir|
      base = File.join(dir, 'Base.mpr')
      ruby_app = File.join(dir, 'ruby-app')
      authored = File.join(dir, 'Authored.mpr')
      build_base(base)
      Mxrb::Exporter.new(base, ruby_app, mode: :ruby).export!
      write_service(ruby_app)

      Mxrb::RubyApp.compile(ruby_app, authored)
      baseline = action_snapshot(authored)
      expect(baseline).to include(
        action_type: 'Microflows$ShowHomePageAction', error_handling: 'Rollback'
      )

      ruby_round_trip = File.join(dir, 'ruby-round-trip')
      ruby_rebuilt = File.join(dir, 'RubyRebuilt.mpr')
      Mxrb::Exporter.new(authored, ruby_round_trip, mode: :ruby).export!
      source = File.read(service_path(ruby_round_trip))
      expect(source).to include('show_home_page')
      expect(source).not_to include('native_document', 'deep_structure:', 'bson_binary(')
      Mxrb::RubyApp.compile(ruby_round_trip, ruby_rebuilt)
      expect(Mxrb.compare(authored, ruby_rebuilt)).to be_identical
      expect(action_snapshot(ruby_rebuilt)).to eq(baseline)

      current = ruby_rebuilt
      2.times do |index|
        exported = File.join(dir, "regular-#{index}")
        rebuilt = File.join(dir, "RegularRebuilt#{index}.mpr")
        Mxrb::Exporter.new(current, exported).export!
        source = Dir.glob(File.join(exported, 'modules', 'App', '**', '*.rb'))
                    .map { File.read(_1) }.find { _1.include?('microflow :NavigateHome') }
        expect(source).to include('show_home_page')
        expect(source).not_to include('native_document', 'deep_structure:', 'bson_binary(')

        generate(exported, rebuilt)
        expect(Mxrb.validate(rebuilt)).to be_valid
        expect(Mxrb.compare(current, rebuilt)).to be_identical
        expect(action_snapshot(rebuilt)).to eq(baseline)
        current = rebuilt
      end
    end
  end

  def build_base(path)
    Mxrb.define(path) do
      mendix_version '11.12.1'
      self.module :App do
        page(:Home) { title 'Home' }
      end
      navigation do
        profile :Responsive, home_page: 'App.Home', app_title: 'Show home page certification'
      end
    end
  end

  def write_service(root)
    path = File.join(root, 'app', 'services', 'app', 'navigate_home.rb')
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, <<~RUBY)
      module App
        class NavigateHome < Mxrb::RubyApp::Service
          mendix_name 'App.NavigateHome'
          flow :microflow do
            show_home_page
          end
        end
      end
    RUBY
  end

  def service_path(root)
    File.join(root, 'app', 'services', 'app', 'navigate_home.rb')
  end

  def action_snapshot(path)
    Mxrb.open(path) do |project|
      flow = project.modules.find { _1.name == 'App' }.microflows.find do |item|
        item.name == 'NavigateHome'
      end
      activity = flow.objects.find { _1['$Type'] == 'Microflows$ActionActivity' }
      action = activity.fetch('Action')
      {
        unit_id: flow.id,
        activity_id: native_id(activity.fetch('$ID')),
        action_id: native_id(action.fetch('$ID')),
        action_type: action.fetch('$Type'),
        error_handling: action.fetch('ErrorHandlingType')
      }
    end
  end

  def native_id(value) = Mxrb::IO::BsonCodec.extract_id(value)

  def generate(exported, rebuilt)
    previous = ENV['MXRB_OUTPUT_PATH']
    ENV['MXRB_OUTPUT_PATH'] = rebuilt
    load File.join(exported, 'project.rb')
  ensure
    previous ? ENV['MXRB_OUTPUT_PATH'] = previous : ENV.delete('MXRB_OUTPUT_PATH')
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/BlockLength, Metrics/MethodLength
