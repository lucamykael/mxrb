# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/AbcSize, Metrics/BlockLength, Metrics/MethodLength
RSpec.describe 'Entity access-rule certification' do
  it 'keeps every Mendix 11 access property and ambiguous identities stable for two cycles' do
    Dir.mktmpdir('mxrb-access-rules-') do |dir|
      current = File.join(dir, 'AccessRules.mpr')
      build_source(current)
      baseline_ids = access_ids(current)

      2.times do |index|
        exported = File.join(dir, "ruby-#{index}")
        rebuilt = File.join(dir, "rebuilt-#{index}.mpr")
        Mxrb::Exporter.new(current, exported).export!
        source = File.read(File.join(exported, 'modules/App/domain/entities/item.rb'))
        expect(source).to include(
          'access_rule "App.Editor"', 'documentation: "Owned items"',
          'create: true', 'delete: true', 'default_rights: "None"',
          ':kind => :attribute', ':kind => :association',
          'xpath: "[Name != \'hidden\']"', 'xpath_caption: "Visible items"', 'id:'
        )
        expect(source).not_to include('native_document', 'deep_structure:', 'bson_binary(')

        generate(exported, rebuilt)
        expect(Mxrb.validate(rebuilt)).to be_valid
        expect(Mxrb.compare(current, rebuilt)).to be_identical
        expect(access_ids(rebuilt)).to eq(baseline_ids)
        current = rebuilt
      end
    end
  end

  def build_source(path)
    Mxrb.define(path) do
      mendix_version '11.12.1'
      security do
        security_level :CheckEverything
        user_role :Editor, module_roles: ['App.Editor']
        user_role :Viewer, module_roles: ['App.Viewer']
      end
      self.module :App do
        module_role :Editor
        module_role :Viewer
        page(:Home) { title 'Access rules' }
        entity(:Account) do
          string :Name
          access_rule 'App.Viewer', default_rights: 'ReadOnly', members: [{
            name: 'Name', reference: 'App.Account.Name', rights: 'ReadOnly', kind: :attribute
          }]
        end
        entity(:Item) do
          string :Name
          association 'App.Account', name: :Item_Account, cardinality: :many_to_one
          2.times do
            access_rule 'App.Editor', documentation: 'Owned items', create: true, delete: true,
                                      default_rights: 'None', xpath: "[Name != 'hidden']",
                                      xpath_caption: 'Visible items', members: [
                                        { name: 'Name', reference: 'App.Item.Name',
                                          rights: 'ReadWrite', kind: :attribute },
                                        { name: 'Item_Account', reference: 'App.Item_Account',
                                          rights: 'ReadOnly', kind: :association }
                                      ]
          end
        end
      end
      navigation do
        profile :Responsive, home_page: 'App.Home', app_title: 'Access rules'
      end
    end
  end

  def access_ids(path)
    Mxrb.open(path) do |project|
      entity = project.entities.find { _1.name == 'Item' }
      entity.access_rules.map do |rule|
        [rule.fetch(:id), rule.fetch(:roles), rule.fetch(:xpath),
         rule.fetch(:members).map { [_1.fetch(:id), _1.fetch(:reference)] }]
      end.sort_by(&:first)
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
# rubocop:enable Metrics/AbcSize, Metrics/BlockLength, Metrics/MethodLength
