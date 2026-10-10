# frozen_string_literal: true

require_relative 'system_domain'

module Mxrb
  module Runtime
    # Signs a persisted System user in the way the Mendix Runtime does: the name
    # ignores case; blocked, inactive and web service users and users without roles
    # are refused before the password is checked; a wrong or empty password counts a
    # failed login and the third one blocks the user for five minutes.
    module SystemSignIn
      MAX_FAILED_LOGINS = 3
      BLOCK_SECONDS = 300

      module_function

      # The signed-in user, or nil.
      def authenticate(store, user_name, password, now: Time.now.utc)
        user = SystemDomain.find_user(store, user_name)
        return unless user

        expire_block(store, user, now)
        return unless allowed?(user) && store.retrieve_association('UserRoles', user).any?
        return failed_login(store, user, now) unless SystemDomain.password_matches?(user.members['Password'], password)

        user.members.merge!('FailedLogins' => 0, 'LastLogin' => now)
        store.commit(user)
        user
      end

      def allowed?(user)
        user.members['Blocked'] != true && user.members['Active'] != false && user.members['WebServiceUser'] != true
      end

      # A block from failed logins expires; a block without BlockedSince stays.
      def expire_block(store, user, now)
        since = user.members['BlockedSince']
        return unless user.members['Blocked'] == true && since && now - since >= BLOCK_SECONDS

        user.members.merge!('Blocked' => false, 'BlockedSince' => nil, 'FailedLogins' => 0)
        store.commit(user)
      end

      def failed_login(store, user, now)
        count = user.members['FailedLogins'].to_i + 1
        user.members['FailedLogins'] = count
        user.members.merge!('Blocked' => true, 'BlockedSince' => now) if count >= MAX_FAILED_LOGINS
        store.commit(user)
        nil
      end
    end
  end
end
