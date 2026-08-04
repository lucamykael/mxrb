# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

RSpec.describe 'qualified access-rule member references' do # rubocop:disable Metrics/BlockLength
  it 'preserves inherited attribute ownership through export and rebuild' do
    Dir.mktmpdir do |dir|
      source = File.join(dir, 'source.mpr')
      exported = File.join(dir, 'ruby')
      rebuilt = File.join(dir, 'rebuilt.mpr')
      Mxrb.define(source) do
        mendix_version '11.12.1'
        self.module :Catalog do
          module_role :User
          entity(:Base) { string :Name }
          entity :Child do
            generalizes 'Catalog.Base'
            access_rule 'Catalog.User', default_rights: 'ReadWrite', members: [{
              name: 'Name', reference: 'Catalog.Base.Name', rights: 'ReadWrite', kind: :attribute
            }]
          end
        end
      end

      expect(member_reference(source)).to eq('Catalog.Base.Name')
      Mxrb::Exporter.new(source, exported).export!(parallel: false)
      child = File.read(File.join(exported, 'modules', 'Catalog', 'domain', 'entities', 'child.rb'))
      expect(child).to include(':reference => "Catalog.Base.Name"')
      with_output(rebuilt) { load File.join(exported, 'project.rb') }
      expect(member_reference(rebuilt)).to eq('Catalog.Base.Name')
      expect(Mxrb.validate(rebuilt)).to be_valid
    end
  end

  def member_reference(path)
    Mxrb.open(path) do |project|
      project.entities.find { _1.name == 'Child' }.access_rules.first.fetch(:members).first
             .fetch(:reference)
    end
  end

  def with_output(path)
    previous = ENV.fetch('MXRB_OUTPUT_PATH', nil)
    ENV['MXRB_OUTPUT_PATH'] = path
    yield
  ensure
    previous ? ENV['MXRB_OUTPUT_PATH'] = previous : ENV.delete('MXRB_OUTPUT_PATH')
  end
end
