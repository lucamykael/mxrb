# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength, Metrics/MethodLength
RSpec.describe 'Project security system-entity access certification' do
  it 'round-trips FileDocument and Image access rules with stable nested identities' do
    Dir.mktmpdir('mxrb-project-security-access-') do |dir|
      current = File.join(dir, 'ProjectSecurityAccess.mpr')
      build_source(current)
      baseline = access_snapshot(current)

      ruby_app = File.join(dir, 'ruby-app')
      ruby_rebuilt = File.join(dir, 'ruby-rebuilt.mpr')
      Mxrb::Exporter.new(current, ruby_app, mode: :ruby).export!
      ruby_source = File.read(File.join(ruby_app, 'app/security/project_security.rb'))
      expect(ruby_source).to include(
        'file_document_access_rule "System.User"',
        'image_access_rule "System.Administrator"',
        'member "Name", reference: "System.FileDocument.Name"'
      )
      expect(ruby_source).not_to include('native_document', 'deep_structure:', 'bson_binary(')
      Mxrb::RubyApp.compile(ruby_app, ruby_rebuilt)
      expect(Mxrb.compare(current, ruby_rebuilt)).to be_identical
      expect(access_snapshot(ruby_rebuilt)).to eq(baseline)

      2.times do |index|
        exported = File.join(dir, "ruby-#{index}")
        rebuilt = File.join(dir, "rebuilt-#{index}.mpr")
        Mxrb::Exporter.new(current, exported).export!
        source = File.read(File.join(exported, 'app/security/security.rb'))
        expect(source).to include(
          'file_document_access_rule "System.User"',
          'image_access_rule "System.Administrator"',
          ':reference => "System.FileDocument.Name"', 'id:'
        )
        expect(source).not_to include('native_document', 'deep_structure:', 'bson_binary(')

        generate(exported, rebuilt)
        expect(Mxrb.validate(rebuilt)).to be_valid
        expect(Mxrb.compare(current, rebuilt)).to be_identical
        expect(access_snapshot(rebuilt)).to eq(baseline)
        current = rebuilt
      end
    end
  end

  def build_source(path)
    Mxrb.define(path) do
      mendix_version '11.12.1'
      self.module :App do
        module_role :Editor
        module_role :Viewer
        page(:Home) { title 'Project security access' }
      end
      security do
        security_level :CheckEverything
        user_role :Editor, admin: true, module_roles: ['App.Editor']
        user_role :Viewer, module_roles: ['App.Viewer']
        admin_user_role :Editor
        file_document_access_rule(
          'System.User', documentation: 'Manage uploaded files', create: true, delete: true,
                         default_rights: :None, xpath: "[Name != 'hidden']",
                         xpath_caption: 'Visible files', members: [{
                           name: 'Name', reference: 'System.FileDocument.Name',
                           rights: :ReadWrite, kind: :attribute
                         }]
        )
        image_access_rule(
          'System.Administrator', documentation: 'View images', default_rights: :ReadOnly
        )
      end
      navigation do
        profile :Responsive, home_page: 'App.Home', app_title: 'Project security access'
      end
    end
  end

  def access_snapshot(path)
    Mxrb.open(path) do |project|
      raw = project.all_units.find do |unit|
        project.parse_bson(unit)['$Type'] == 'Security$ProjectSecurity'
      end
      document = project.parse_bson(raw)
      {
        unit_id: raw.fetch('UnitID'), document_id: document.fetch('$ID'),
        file_document: container_snapshot(document.fetch('FileDocumentAccess')),
        image: container_snapshot(document.fetch('ImageAccess'))
      }
    end
  end

  def container_snapshot(container)
    rules = Mxrb::IO::BsonCodec.parse_array(container.fetch('AccessRules'))[:items]
    {
      id: container.fetch('$ID'), type: container.fetch('$Type'),
      rules: rules.map do |rule|
        parsed = Mxrb::Model::Entity.parse_access_rule(rule)
        parsed.merge(members: parsed.fetch(:members).sort_by { _1.fetch(:reference) })
      end
    }
  end

  def generate(exported, rebuilt)
    previous = ENV['MXRB_OUTPUT_PATH']
    ENV['MXRB_OUTPUT_PATH'] = rebuilt
    load File.join(exported, 'project.rb')
  ensure
    previous ? ENV['MXRB_OUTPUT_PATH'] = previous : ENV.delete('MXRB_OUTPUT_PATH')
  end
end
# rubocop:enable Metrics/BlockLength, Metrics/MethodLength
