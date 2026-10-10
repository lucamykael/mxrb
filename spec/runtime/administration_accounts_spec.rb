# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# The Administration module of a real project, exported to editable Ruby.
# rubocop:disable Metrics/BlockLength
RSpec.describe 'Administration accounts in an exported application' do
  let(:password) { 'Player#Pass2026' }

  around do |example|
    path = ENV.fetch('MXRB_ACCEPTANCE_MPRS', '').split(File::PATH_SEPARATOR)
              .find { File.basename(_1) == 'Sudoku.mpr' && File.file?(_1) }
    skip 'the Sudoku acceptance project is not present in this environment' unless path

    Dir.mktmpdir do |directory|
      FileUtils.cp_r(File.dirname(path), File.join(directory, 'source'))
      source = File.join(directory, 'source', 'Sudoku.mpr')
      target = File.join(directory, 'ruby')
      Mxrb::Exporter.new(source, target, mode: :ruby).export!
      @application = Mxrb::RubyApp::Application.new(
        target, process: { 'MXRB_DATABASE_PATH' => ':memory:', 'MXRB_ADMIN_PASSWORD' => 'Adm1n!Pass#2026' }
      )
      example.run
    ensure
      @application&.close
      Mxrb::RubyApp::Registry.reset!
    end
  end

  def context(user, secret)
    session = @application.session_manager.login(user, secret)
    @application.session_manager.authenticate("Bearer #{session.fetch(:token)}")
  end

  def password_data(store, account, old_password, new_password, confirm = new_password)
    store.create('Administration.AccountPasswordData').tap do |data|
      data.members.merge!('OldPassword' => old_password, 'NewPassword' => new_password,
                          'ConfirmPassword' => confirm, 'AccountPasswordData_Account' => account)
    end
  end

  it 'creates an account, changes its password and signs in with the Administration flows' do
    store = @application.send(:bridge).store
    admin = context('MxAdmin', 'Adm1n!Pass#2026')
    expect(admin.user_roles).to eq(['Administrator'])
    account = store.create('Administration.Account')
    account.members.merge!('Name' => 'player', 'FullName' => 'Player One',
                           'UserRoles' => store.retrieve('System.UserRole').select { _1.members['Name'] == 'User' })
    data = password_data(store, account, '', password)
    @application.call_service('Administration.SaveNewAccount', { 'AccountPasswordData' => data }, context: admin)
    expect(context('player', password).user_roles).to eq(['User'])

    player = context('PLAYER', password)
    wrong = password_data(store, account, 'not it', 'Changed#Pass2026')
    @application.call_service('Administration.ChangeMyPassword', { 'AccountPasswordData' => wrong }, context: player)
    expect { context('player', 'Changed#Pass2026') }.to raise_error(Mxrb::RubyApp::AuthenticationError)
    right = password_data(store, account, password, 'Changed#Pass2026')
    @application.call_service('Administration.ChangeMyPassword', { 'AccountPasswordData' => right }, context: player)
    expect(context('player', 'Changed#Pass2026').user).to eq(account.id)
  end
end
# rubocop:enable Metrics/BlockLength
