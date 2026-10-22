# frozen_string_literal: true

require 'spec_helper'

# Domain-model shapes MxBuild 10.24 writes: System parents keep the flags of the
# version's System module, indexes carry no association pointer before Mendix
# 11, view-entity associations read one way, and the seeded System module's
# access rules name the project's own user roles.
# rubocop:disable Metrics/BlockLength
RSpec.describe 'Runtime domain shapes' do
  def source(version, security: nil)
    Struct.new(:version, :security) do
      def units_of(_type) = []
      def units = []
      def documents(type) = type == 'Security$ProjectSecurity' && security ? [security] : []
    end.new(version, security)
  end

  it 'inherits the flags of a System parent from the System module of the version' do
    compiler = Mxrb::Compiler::DomainDocumentCompiler.new(source('10.24.18.103793'))
    expect(compiler.send(:inherited_flags, 'System.Paging')).to include('Persistable' => false, 'HasOwnerAttr' => false)
    expect(compiler.send(:inherited_flags, 'System.User')).to include('Persistable' => true, 'HasOwnerAttr' => true)
    expect(compiler.send(:inherited_flags, 'System.Unknown')).to include('Persistable' => true)
    expect(Mxrb::Compiler::DomainDocumentCompiler.new(source('5.0.0')).send(:inherited_flags, 'System.Paging'))
      .to include('Persistable' => true)
  end

  it 'writes an association pointer on indexed attributes from Mendix 11 on' do
    attribute = { '$Type' => 'DomainModels$IndexedAttribute', 'Ascending' => true, 'Type' => 'Normal' }
    ten = Mxrb::Compiler::DomainDocumentCompiler.new(source('10.24.18.103793'))
    expect(ten.send(:compile_indexed_attribute, attribute)).not_to have_key('AssociationPointer')
    eleven = Mxrb::Compiler::DomainDocumentCompiler.new(source('11.12.1'))
    pointer = eleven.send(:compile_indexed_attribute, attribute).fetch('AssociationPointer')
    expect(Mxrb::IO::BsonCodec.extract_id(pointer)).to eq('00000000-0000-0000-0000-000000000000')
  end

  it 'reads a view-entity association from parent to child only' do
    security = Mxrb::Compiler::DomainSecurityCompiler.new(source('11.12.1'))
    behavior = { 'DeleteBehavior' => { 'ParentDeleteBehavior' => 'DeleteMeButKeepReferences',
                                       'ChildDeleteBehavior' => 'DeleteMeButKeepReferences' } }
    oql = behavior.merge('Name' => 'LocationId', 'Source' => { '$Type' => 'DomainModels$OqlViewAssociationSource' })
    expect(security.association(oql, 'Views')).to include('Navigability' => 'ParentToChild')
    stored = behavior.merge('Name' => 'Order_Customer', 'Source' => 'DomainModels$StoredAssociationSource')
    expect(security.association(stored, 'App')).to include('Navigability' => 'BothDirections')
  end

  it 'names the project user roles that hold the System module roles of seeded access rules' do
    security = { 'UserRoles' => [3, { 'Name' => 'Admin', 'ModuleRoles' => [1, 'System.Administrator'] },
                                 { 'Name' => 'Member', 'ModuleRoles' => [1, 'System.User', 'App.User'] }] }
    package = Mxrb::Compiler::SystemModelSeed.for('10.24.18.103793').package
    materializer = Mxrb::Compiler::DomainModelMaterializer.new('App.mpr', deployment: 'deployment')
    domain = materializer.send(:system_domain, package, source('10.24.18.103793', security:))
    entities = domain.fetch('Entities').to_h { [_1['QualifiedName'], _1] }
    user_rules = entities.fetch('System.User').fetch('AccessRules').map { _1['AllowedUserRoles'] }
    expect(user_rules).to include(%w[Admin Member])
    expect(entities.fetch('System.XASInstance').fetch('AccessRules').map { _1['AllowedUserRoles'] }).to eq([['Admin']])
    expect(materializer.send(:system_domain, Mxrb::Compiler::ModelPackage.empty, source('10.24.18.103793'))).to be_nil
  end
end
# rubocop:enable Metrics/BlockLength
