# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength, Metrics/MethodLength
RSpec.describe Mxrb::Compiler::DomainModelMaterializer do
  around do |example|
    Dir.mktmpdir do |root|
      @mpr = File.join(root, 'Clinic.mpr')
      @deployment = File.join(root, 'deployment')
      define_project
      FileUtils.mkdir_p(File.join(@deployment, 'model'))
      sentinel = { '$ID' => '44444444-4444-4444-8444-444444444444', '$Type' => 'Projects$Project' }
      File.binwrite(File.join(@deployment, 'model', 'model.mdp'),
                    Mxrb::IO::BsonCodec.serialize(sentinel))
      example.run
    end
  end

  def define_project
    Mxrb.define(@mpr) do
      mendix_version '11.12.1'
      security do
        security_level :CheckEverything
        user_role :User, module_roles: ['Clinic.User']
      end
      self.module(:Clinic) do
        module_role :User
        entity(:Animal) do
          string :Name, required: true, length: 80
          string :Description
          datetime :BirthDate
          index :Name
          access_rule 'Clinic.User', read: :all, write: [:Name], create: true
        end
      end
    end
  end

  it 'flattens entities, attributes, validation, indexes, and access roles' do
    result = described_class.new(@mpr, deployment: @deployment).materialize
    expect(result).to have_attributes(domain_models: 1, entities: 1)
    package = Mxrb::Compiler::ModelPackage.read(result.model_path)
    domain = package.documents.find { _1['$Type'] == 'DomainModels$DomainModel' }
    expect(domain.keys).to eq(%w[$ID $Type Entities Associations CrossAssociations])
    entity = domain.fetch('Entities').first
    expect(entity).to include(
      'QualifiedName' => 'Clinic.Animal', 'UnqualifiedName' => 'Animal', 'Events' => []
    )
    expect(entity['MaybeGeneralization']).to include(
      'Generalization' => '', 'Persistable' => true, 'HasOwnerAttr' => false, 'Key' => nil
    )
    expect(entity['MaybeGeneralization'].keys).to eq(
      %w[$ID $Type Key Persistable HasCreatedDateAttr HasChangedDateAttr HasOwnerAttr
         HasChangedByAttr Generalization]
    )
    attributes = entity['Attributes'].to_h { [_1['Name'], _1] }
    expect(attributes.dig('Name', 'Type')).to include(
      '$Type' => 'DomainModels$StringAttributeType', 'Length' => 80
    )
    expect(attributes.dig('Description', 'Type', 'Length')).to eq(200)
    expect(attributes.dig('BirthDate', 'Type', 'LocalizeDate')).to be(true)
    expect(entity['ValidationRules'].first['Message']).not_to have_key('Items')
    indexed = entity['Indexes'].first['Attributes']
    expect(indexed).to all(include('AttributePointer', 'AssociationPointer'))
    expect(Mxrb::IO::BsonCodec.extract_id(indexed.first['AssociationPointer']))
      .to eq('00000000-0000-0000-0000-000000000000')
    expect(entity['AccessRules'].first).to include(
      'AllowedUserRoles' => ['User'], 'AllowCreate' => true, 'AllowDelete' => false
    )
    expect(entity.dig('AccessRules', 0, 'MemberAccesses', 0).keys).to eq(
      %w[$ID $Type Attribute Association AccessRights]
    )
  end
end
# rubocop:enable Metrics/BlockLength, Metrics/MethodLength
