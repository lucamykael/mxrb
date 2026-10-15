# frozen_string_literal: true

require 'digest'
require 'json'
require 'securerandom'
require 'time'
require_relative '../runtime/shared_store'
require_relative '../runtime/system_sign_in'

module Mxrb
  module RubyApp
    class AuthenticationError < StandardError; end

    # The user's time zone when set, otherwise the browser's, otherwise UTC.
    SessionTimeZone = Data.define(:user_time_zone) do
      def call(user, client) = (user && user_time_zone&.call(user)) || Runtime::TimeZones.valid(client) || 'UTC'
    end

    # Environment-backed identities and short-lived opaque sessions for the
    # standalone Ruby server. Production deployments can put the same adapter
    # behind their own Rack authentication and provide static bearer tokens.
    class SessionManager # rubocop:disable Metrics/ClassLength
      attr_reader :ttl

      # rubocop:disable Metrics/ParameterLists
      # directory returns the application store whose persisted System users sign in
      # when a name is not configured in MXRB_USERS_JSON.
      def initialize(access_control, users: ENV['MXRB_USERS_JSON'],
                     tokens: ENV['MXRB_AUTH_TOKENS'], ttl: ENV.fetch('MXRB_SESSION_TTL', '3600'),
                     clock: -> { Time.now.utc }, store: nil, directory: nil, user_time_zone: nil)
        @access_control = access_control
        @time_zone = SessionTimeZone.new(user_time_zone)
        @directory = directory
        @users = parse_map(users, 'MXRB_USERS_JSON')
        @static_tokens = parse_map(tokens, 'MXRB_AUTH_TOKENS')
        @ttl = Integer(ttl)
        raise ArgumentError, 'session TTL must be positive' unless @ttl.positive?

        @clock = clock
        @store = store || Runtime::MemorySharedStore.new
      end
      # rubocop:enable Metrics/ParameterLists

      def anonymous(client_time_zone: nil)
        @access_control.context(attributes: { 'time_zone' => @time_zone.call(nil, client_time_zone) })
      end

      # client_time_zone is the IANA zone the browser reports (X-Mxrb-Time-Zone).
      def authenticate(header, client_time_zone: nil)
        token = bearer_token(header)
        return anonymous(client_time_zone:) unless token

        static = @static_tokens[token]
        return context_for(static, client_time_zone, token) if static

        session = @store.read_session(token, now: @clock.call)
        raise AuthenticationError, 'invalid or expired bearer token' unless session

        context_for(session.identity, client_time_zone, token)
      end

      # A guest's session under the guest user role, as a request handler starts
      # one; its token is its id, which the handler sets as the session cookie.
      def guest(roles)
        token = SecureRandom.uuid
        identity = { 'roles' => Array(roles).map(&:to_s), 'attributes' => { 'anonymous' => true },
                     '_csrf' => SecureRandom.urlsafe_base64(32) }
        @store.write_session(token:, identity:, expires_at: @clock.call + ttl)
        token
      end

      # The id of the session a token opens: the token itself when it is a UUID,
      # as a guest's is, otherwise a UUID derived from it.
      def self.session_id(token)
        return token if token.match?(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)

        Digest::SHA256.hexdigest(token)[0, 32].unpack('a8a4a4a4a12').join('-')
      end

      def login(username, password)
        identity = authenticated_identity(username, password)

        token = SecureRandom.urlsafe_base64(32)
        csrf = SecureRandom.urlsafe_base64(32)
        expires_at = @clock.call + ttl
        profile = identity.slice('roles', 'user_roles', 'module_roles', 'attributes')
                          .merge('user' => identity.fetch('user', username.to_s), '_csrf' => csrf)
        context = context_for(profile)
        @store.write_session(token:, identity: profile, expires_at:)
        { token:, csrf:, expires_at: expires_at.iso8601, user: context.user, roles: context.user_roles }
      end

      def logout(header)
        token = bearer_token(header)
        token && @store.delete_session(token)
      end

      def csrf_token(header)
        token = bearer_token(header)
        session = token && @store.read_session(token, now: @clock.call)
        session&.identity&.fetch('_csrf', nil)
      end

      def valid_csrf?(header, supplied)
        expected = csrf_token(header).to_s
        !expected.empty? && secure_compare(expected, supplied.to_s)
      end

      private

      def authenticated_identity(username, password)
        identity = @users[username.to_s]
        return identity if identity && password_matches?(identity, password)

        system = !identity && @directory && system_identity(@directory.call, username, password)
        raise AuthenticationError, 'invalid username or password' unless system

        system
      end

      # A persisted System.User: the session user is its ID, its roles are the user roles.
      def system_identity(store, username, password)
        user = Runtime::SystemSignIn.authenticate(store, username, password, now: @clock.call)
        roles = user && store.retrieve_association('UserRoles', user).map { _1.members['Name'] }
        user && { 'user' => user.id, 'roles' => roles }
      end

      def context_for(raw, client_time_zone = nil, token = nil)
        value = raw.is_a?(Hash) ? raw : {}
        attributes = value['attributes'] || {}
        attributes = attributes.merge('session_id' => self.class.session_id(token)) if token
        zone = attributes['time_zone'] || @time_zone.call(value['user'], client_time_zone)
        @access_control.context(
          user: value['user'], user_roles: value['roles'] || value['user_roles'],
          module_roles: value['module_roles'], attributes: attributes.merge('time_zone' => zone)
        )
      end

      def bearer_token(header)
        match = /\ABearer\s+(.+)\z/i.match(header.to_s.strip)
        match && match[1]
      end

      def password_matches?(identity, supplied)
        expected = identity['password_digest'].to_s
        expected = "plain$#{identity['password']}" if expected.empty? && identity.key?('password')
        scheme, value = expected.split('$', 2)
        actual = case scheme
                 when 'sha256' then Digest::SHA256.hexdigest(supplied.to_s)
                 when 'plain' then supplied.to_s
                 else return false
                 end
        secure_compare(actual, value.to_s)
      end

      def secure_compare(left, right)
        return false unless left.bytesize == right.bytesize

        left.bytes.zip(right.bytes).reduce(0) { |difference, pair| difference | (pair[0] ^ pair[1]) }.zero?
      end

      def parse_map(raw, name)
        return {} if raw.nil? || raw.to_s.strip.empty?

        parsed = JSON.parse(raw)
        raise ArgumentError, "#{name} must contain a JSON object" unless parsed.is_a?(Hash)

        parsed
      rescue JSON::ParserError => e
        raise ArgumentError, "invalid #{name}: #{e.message}"
      end
    end
  end
end
