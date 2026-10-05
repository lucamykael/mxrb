# frozen_string_literal: true

require 'mxrb'
require 'tmpdir'

# Build native rules through the editable Ruby contract. The temporal bound is
# date-only: Runtime 11.12.1 rejects a time literal that MxBuild accepts.
# rubocop:disable Metrics/BlockLength
Dir.mktmpdir('mxrb-native-validation') do |root|
  destination = ENV.fetch('MXRB_OUTPUT_PATH')
  source = File.join(root, 'seed', 'Application.mpr')
  FileUtils.mkdir_p(File.dirname(source))
  ENV['MXRB_OUTPUT_PATH'] = source
  Mxrb.define(source) do
    mendix_version '11.12.1'
    self.module :Rules do
      entity(:Base) { string :Name }
      entity(:Child) { generalizes 'Rules.Base' }
      entity(:Sibling) { generalizes 'Rules.Base' }
      entity :Range do
        decimal :Amount
        decimal :Limit
      end
      entity(:Exact) { string :Name }
      entity(:Length) { string :Name }
      entity(:Day) { datetime :Value }
      microflow :Load do
        return_type 'Rules.Base'
        create_object 'Rules.Base', as: :item, set: { Name: "'Home'" }
        return_value '$item'
      end
      page :Home do
        title 'Validation oracle'
        data_source microflow: 'Rules.Load'
        text_box :Name, attribute: 'Rules.Base.Name', caption: 'Name'
      end
    end
    navigation { profile :Responsive, home_page: 'Rules.Home' }
  end
  app = File.join(root, 'ruby')
  Mxrb::Exporter.new(source, app, mode: :ruby).export!
  File.write(File.join(app, 'app', 'models', 'zz_validation_rules.rb'), <<~'RULES')
    base = Mxrb::RubyApp::Registry.fetch(:record, 'Rules.Base')
    base.validation_rule('Name', kind: :required) { translation 'en_US', 'Required name' }
    base.validation_rule('Name', kind: :unique) { translation 'en_US', 'Unique name' }
    range = Mxrb::RubyApp::Registry.fetch(:record, 'Rules.Range')
    range.validation_rule('Amount', kind: 'DomainModels$RangeRuleInfo',
      rule_info: { 'TypeOfRange' => 'Between', 'UseMinValue' => true, 'MinValue' => '1.5',
                   'UseMaxValue' => false, 'MaxAttribute' => 'Rules.Range.Limit', 'MaxValue' => '' , 'MinAttribute' => '' }) do
      translation 'en_US', 'Amount must be in range'
    end
    exact = Mxrb::RubyApp::Registry.fetch(:record, 'Rules.Exact')
    exact.validation_rule('Name', kind: 'DomainModels$EqualsToRuleInfo',
      rule_info: { 'UseValue' => true, 'Value' => 'Expected', 'EqualsToAttribute' => '' }) do
      translation 'en_US', 'Name must equal Expected'
    end
    length = Mxrb::RubyApp::Registry.fetch(:record, 'Rules.Length')
    length.validation_rule('Name', kind: 'DomainModels$MaxLengthRuleInfo', rule_info: { 'MaxLength' => 2 }) do
      translation 'en_US', 'Maximum two characters'
    end
    day = Mxrb::RubyApp::Registry.fetch(:record, 'Rules.Day')
    day.validation_rule('Value', kind: 'DomainModels$RangeRuleInfo',
      rule_info: { 'TypeOfRange' => 'GreaterThanOrEqualTo', 'UseMinValue' => true, 'MinValue' => '2026-10-05',
                   'UseMaxValue' => true, 'MaxValue' => '', 'MinAttribute' => '', 'MaxAttribute' => '' }) do
      translation 'en_US', 'Date minimum'
    end
  RULES
  Mxrb::RubyApp.compile(app, destination, mendix_version: '11.12.1')
ensure
  ENV['MXRB_OUTPUT_PATH'] = destination
end
# rubocop:enable Metrics/BlockLength
