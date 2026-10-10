# frozen_string_literal: true

require 'mxrb'

# Native oracle for signing in with persisted System users. Views.Setup runs after
# startup and creates the users; script/login_native_oracle then posts the logins of
# steps.json to /xas/ and reads GET /rest/users/v1/users after each step.
USERS = [
  ['alice', 'Member', true, false, false], ['bob', 'Member', false, false, false],
  ['carol', 'Member', true, true, false], ['erin', 'Member', true, false, true],
  ['frank', nil, true, false, false], ['gina', 'Member', true, false, false]
].freeze
# rubocop:disable Metrics/BlockLength
Mxrb.define(ENV.fetch('MXRB_OUTPUT_PATH')) do
  mendix_version '11.12.1'
  self.module :Views do
    module_role :User
    microflow :Setup do
      return_type :Boolean
      USERS.each do |name, role, active, blocked, web|
        retrieve_objects 'System.UserRole', as: "#{name}_role", single: true, xpath: "[Name = '#{role}']" if role
        create_object 'System.User', as: name, commit: true do
          set :Name, to: "'#{name}'"
          set :Password, to: "'Secret#1'"
          set :Active, to: active.to_s
          set :Blocked, to: blocked.to_s
          set :WebServiceUser, to: web.to_s
          set_association 'System.UserRoles', to: "$#{name}_role" if role
        end
      end
      return_value 'true'
    end
    microflow :Users do
      return_type :String
      retrieve_objects 'System.User', as: :users, sort: [['System.User.Name', 'Ascending']]
      create_variable :text, type: :String, value: "''"
      loop_over :users, as: :user do
        change_variable :text, to: "$text + $user/Name + '|' + toString($user/Active) + '|' + " \
                                   "toString($user/Blocked) + '|' + toString($user/BlockedSince != empty) + '|' + " \
                                   "toString($user/FailedLogins) + '|' + toString($user/LastLogin != empty) + ';'"
      end
      return_value '$text'
    end
    microflow :Me do
      allowed_roles 'Views.User'
      return_type :String
      return_value "if $currentUser = empty then '<anonymous>' else $currentUser/Name"
    end
    page :Home do
      allowed_roles 'Views.User'
      title 'Login oracle'
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
    user_role 'Member', module_roles: ['Views.User']
    admin_user_role 'Administrator'
  end
  navigation { profile :Responsive, home_page: 'Views.Home' }
end
# rubocop:enable Metrics/BlockLength
