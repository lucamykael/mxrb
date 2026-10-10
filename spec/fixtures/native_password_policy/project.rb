# frozen_string_literal: true

require 'mxrb'

# Native oracle for the password policy of persisted users: each anonymous GET
# rest/policy/<case> runs one microflow that creates or changes a user and commits.
# Run with script/login_native_oracle and steps.json.
CREATE = {
  'Short' => 'Ab1!xyz', 'NoDigit' => 'Abcdefg!', 'NoUpper' => 'abcdef1!', 'NoLower' => 'ABCDEF1!',
  'NoSymbol' => 'Abcdefg1', 'Valid' => 'Abcdef1!', 'Empty' => '', 'Spaces' => 'Ab 1!   '
}.freeze
# rubocop:disable Metrics/BlockLength
Mxrb.define(ENV.fetch('MXRB_OUTPUT_PATH')) do
  mendix_version '11.12.1'
  self.module :Views do
    module_role :User
    entity :Account do
      generalizes 'System.User'
      string :FullName
    end
    microflow :Setup do
      return_type :Boolean
      create_object 'System.User', as: :base, commit: true do
        set :Name, to: "'base'"
        set :Password, to: "'Abcdef1!'"
      end
      return_value 'true'
    end
    CREATE.each do |name, password|
      microflow "Create#{name}" do
        return_type :String
        create_object 'System.User', as: :user, commit: true do
          set :Name, to: "'#{name.downcase}'"
          set :Password, to: "'#{password}'"
        end
        return_value "'ok'"
      end
    end
    microflow :ChangeWeak do
      return_type :String
      retrieve_objects 'System.User', as: :user, single: true, xpath: "[Name = 'base']"
      change_object :user, commit: true do
        set :Password, to: "'weak'"
      end
      return_value "'ok'"
    end
    microflow :ChangeOther do
      return_type :String
      retrieve_objects 'System.User', as: :user, single: true, xpath: "[Name = 'base']"
      change_object :user, commit: true do
        set :Blocked, to: 'false'
      end
      return_value "'ok'"
    end
    microflow :AccountWeak do
      return_type :String
      create_object 'Views.Account', as: :account, commit: true do
        set 'System.User.Name', to: "'account'"
        set 'System.User.Password', to: "'weak'"
      end
      return_value "'ok'"
    end
    microflow :Users do
      return_type :String
      retrieve_objects 'System.User', as: :users, sort: [['System.User.Name', 'Ascending']]
      create_variable :text, type: :String, value: "''"
      loop_over :users, as: :user do
        change_variable :text, to: "$text + $user/Name + ';'"
      end
      return_value '$text'
    end
    page :Home do
      allowed_roles 'Views.User'
      title 'Password policy oracle'
    end
    published_rest_service :Policy, path: 'rest/policy', version: '1.0', requires_authentication: false do
      resource :cases do
        (CREATE.keys.map { "Create#{_1}" } + %w[ChangeWeak ChangeOther AccountWeak]).each do |flow|
          get flow.downcase.to_sym, path: flow.downcase, microflow: "Views.#{flow}"
        end
      end
    end
    published_rest_service :Users, path: 'rest/users', version: '1.0', requires_authentication: false do
      resource :users do
        get :index, path: '', microflow: 'Views.Users'
      end
    end
  end
  security do
    security_level 'CheckEverything'
    admin_user 'MxAdmin', password: 'Adm1n!pass'
    user_role 'Administrator', admin: true, module_roles: ['Views.User']
    admin_user_role 'Administrator'
    password_policy MinimumLength: 8, RequireDigit: true, RequireMixedCase: true, RequireSymbol: true
  end
  navigation { profile :Responsive, home_page: 'Views.Home' }
end
# rubocop:enable Metrics/BlockLength
