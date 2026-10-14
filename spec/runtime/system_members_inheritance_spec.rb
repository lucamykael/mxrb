# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# Specializations store the system members (owner, dates, changedBy) of their root
# generalization; System.User and System.FileDocument store all four, as in the
# Mendix 11.12.1 System model. XPath reaches them through System.owner/changedBy.
# rubocop:disable Metrics/BlockLength
RSpec.describe 'Inherited system members' do
  let(:all_members) { %i[owner created_date changed_date changed_by] }

  it 'resolves System.owner and System.changedBy in XPath to the stored user' do
    store = Mxrb::Runtime::Native::Store.new
    alice = store.create(Mxrb::Runtime::SystemDomain::USER).tap { _1.members['Name'] = 'alice' }
    owned = store.create('App.Note').tap { _1.members.merge!('Owner' => alice.id, 'changedBy' => alice.id) }
    foreign = store.create('App.Note').tap { _1.members['Owner'] = 'someone-else' }
    orphan = store.create('App.Note')
    context = Mxrb::Runtime::SecurityContext.new(user: alice.id)
    filter = lambda do |source|
      Mxrb::Runtime::XPath.new(source, store:, context:).filter([owned, foreign, orphan])
    end

    expect(filter.call("[System.owner = '[%CurrentUser%]']")).to eq([owned])
    expect(filter.call('[System.owner = [%CurrentUser%]]')).to eq([owned])
    expect(filter.call("[System.owner/System.User/Name = 'alice']")).to eq([owned])
    expect(filter.call("[System.changedBy = '[%CurrentUser%]']")).to eq([owned])
    expect(filter.call('[System.owner = empty]')).to eq([foreign, orphan])
  end

  it 'derives the stored system members of a specialization from its root' do
    entity = Struct.new(:generalization, :system_members)
    root = entity.new({ '$Type' => 'DomainModels$NoGeneralization' }, { owner: true, created_date: true })
    lookup = {
      'App.Base' => root,
      'App.Middle' => entity.new({ 'Generalization' => 'App.Base' }, {}),
      'App.Loop' => entity.new({ 'Generalization' => 'App.Loop' }, {})
    }
    migrator = Mxrb::Runtime::SchemaMigrator
    leaf = entity.new({ 'Generalization' => 'App.Middle' }, { owner: false })
    account = entity.new({ 'Generalization' => 'System.User' }, {})
    stray = entity.new({ 'Generalization' => 'App.Missing' }, {})

    expect(migrator.inherited_system_members(leaf, lookup)).to eq(owner: true, created_date: true)
    expect(migrator.inherited_system_members(account, lookup).select { _2 }.keys).to eq(all_members)
    expect(migrator.inherited_system_members(stray, lookup)).to eq({})
    expect(migrator.inherited_system_members(lookup.fetch('App.Loop'), lookup)).to eq({})
    expect(migrator.inherited_system_members(entity.new(nil, nil), lookup)).to eq({})
    expect(migrator.system_columns(owner: true, created_date: false, unknown: true).keys).to eq([:owner])

    user = Mxrb::Runtime::SystemDomain.entity_schemas([]).find { _1.name == Mxrb::Runtime::SystemDomain::USER }
    expect(user.system_members.keys).to eq(all_members)
  end

  context 'with the Sudoku acceptance project exported to Ruby' do
    around do |example|
      path = ENV.fetch('MXRB_ACCEPTANCE_MPRS', '').split(File::PATH_SEPARATOR)
                .find { File.basename(_1) == 'Sudoku.mpr' && File.file?(_1) }
      skip 'the Sudoku acceptance project is not present in this environment' unless path

      Dir.mktmpdir do |directory|
        FileUtils.cp_r(File.dirname(path), File.join(directory, 'source'))
        target = File.join(directory, 'ruby')
        Mxrb::Exporter.new(File.join(directory, 'source', 'Sudoku.mpr'), target, mode: :ruby).export!
        @application = Mxrb::RubyApp::Application.new(
          target, process: { 'MXRB_DATABASE_PATH' => File.join(directory, 'app.sqlite3') }
        )
        example.run
      ensure
        @application&.close
        Mxrb::RubyApp::Registry.reset!
      end
    end

    it 'persists the owner of a System.User specialization and filters on it' do
      store = @application.send(:bridge).store
      expect(store.schema.entity('Administration.Account').system_members.keys).to eq(all_members)
      ids = %w[alice bob].map do |name|
        account = store.create('Administration.Account')
        account.members.merge!('Name' => name, 'Password' => 'Disposable#Pass9')
        store.commit(account)
        account.id
      end
      ids.each do |id|
        row = store.find('Administration.Account', id)
        row.members['Owner'] = id
        store.commit(row)
      end
      @application.send(:release_runtime_cache)

      context = @application.access_control.context(user: ids.first, roles: ['Administrator'])
      owned = @application.records('Administration.Account', context:,
                                                             xpath: "[System.owner = '[%CurrentUser%]']")
      expect(owned.map { _1[:id] }).to eq([ids.first])
    end
  end
end
# rubocop:enable Metrics/BlockLength
