# frozen_string_literal: true

require 'mxrb'

# Native oracle for the persisted System users: seeded user roles and administrator,
# password hashing and System.VerifyPassword. Views.RunAll runs after startup and logs
# "ORACLE <case>=<value>"; run with script/oql_native_oracle.
verify = {
  'AliceRight' => %w[alice Secret#1], 'AliceWrong' => %w[alice secret#1], 'AliceUpper' => %w[ALICE Secret#1],
  'Nobody' => %w[nobody Secret#1], 'AliceEmpty' => ['alice', ''], 'BobInactive' => %w[bob Secret#1],
  'CarolBlocked' => %w[carol Secret#1], 'Admin' => ['MxAdmin', 'Adm1n!pass'], 'DaveAccount' => %w[dave Dave#2],
  'WebService' => %w[erin Secret#1]
}
# rubocop:disable Metrics/BlockLength
Mxrb.define(ENV.fetch('MXRB_OUTPUT_PATH')) do
  mendix_version '11.12.1'
  self.module :Views do
    module_role :User
    entity :Account do
      generalizes 'System.User'
      string :FullName
    end
    microflow :Users do
      [['alice', true, false, false], ['bob', false, false, false], ['carol', true, true, false],
       ['erin', true, false, true]].each do |name, active, blocked, web|
        create_object 'System.User', as: name, commit: true do
          set :Name, to: "'#{name}'"
          set :Password, to: "'Secret#1'"
          set :Active, to: active.to_s
          set :Blocked, to: blocked.to_s
          set :WebServiceUser, to: web.to_s
        end
      end
      create_object 'Views.Account', as: :dave, commit: true do
        set 'System.User.Name', to: "'dave'"
        set 'System.User.Password', to: "'Dave#2'"
        set :FullName, to: "'Dave Account'"
      end
    end
    verify.each do |name, (user, password)|
      microflow "Verify#{name}" do
        call_java 'System.VerifyPassword', as: :ok do
          argument 'System.VerifyPassword.userName', "'#{user}'"
          argument 'System.VerifyPassword.password', "'#{password}'"
        end
        log_message "ORACLE Verify#{name}={1}", node: "'ORACLE'", parameters: ['toString($ok)']
      end
    end
    microflow :Inspect do
      retrieve_objects 'System.UserRole', as: :roles, sort: [['System.UserRole.Name', 'Ascending']]
      create_variable :names, type: :String, value: "''"
      loop_over :roles, as: :role do
        change_variable :names, to: "$names + $role/Name + ':' + $role/ModelGUID + ':' + $role/Description + ','"
      end
      log_message 'ORACLE Roles={1}', node: "'ORACLE'", parameters: ['$names']
      retrieve_objects 'System.User', as: :users, sort: [['System.User.Name', 'Ascending']]
      create_variable :people, type: :String, value: "''"
      loop_over :users, as: :user do
        retrieve_association :user, association: 'System.UserRoles', as: :held
        change_variable :people, to: "$people + $user/Name + '|' + toString($user/Active) + '|' + " \
                                     "toString($user/Blocked) + '|' + toString($user/FailedLogins) + '|' + " \
                                     "toString(length($held)) + ';'"
      end
      log_message 'ORACLE Users={1}', node: "'ORACLE'", parameters: ['$people']
      retrieve_objects 'Views.Account', as: :accounts
      log_message 'ORACLE Accounts={1}', node: "'ORACLE'", parameters: ['toString(length($accounts))']
    end
    microflow :RunAll do
      allowed_roles 'Views.User'
      return_type :Boolean
      call_microflow 'Views.Users'
      verify.each_key { call_microflow "Views.Verify#{_1}" }
      call_microflow 'Views.Inspect'
      return_value 'true'
    end
    page :Home do
      allowed_roles 'Views.User'
      title 'System users oracle'
      button('Run', caption: 'Run') { on_click microflow: 'Views.RunAll' }
    end
  end
  security do
    security_level 'CheckEverything'
    admin_user 'MxAdmin', password: 'Adm1n!pass'
    user_role 'Administrator', admin: true, module_roles: ['Views.User'],
                               guid: '0b6a8c1e-2f3d-4e5a-9b7c-1d2e3f4a5b6c', description: 'Runs everything'
    user_role 'Member', module_roles: ['Views.User'], guid: '7c8d9e0f-1a2b-4c3d-8e9f-0a1b2c3d4e5f'
    admin_user_role 'Administrator'
  end
  navigation { profile :Responsive, home_page: 'Views.Home' }
end
# rubocop:enable Metrics/BlockLength
