# frozen_string_literal: true

require 'digest'
require 'json'
require 'securerandom'
require 'time'
require_relative '../runtime/shared_store'

module Mxrb
  module RubyApp
    class AuthenticationError < StandardError; end

    # Environment-backed identities and short-lived opaque sessions for the
    # standalone Ruby server. Production deployments can put the same adapter
    # behind their own Rack authentication and provide static bearer tokens.
    class SessionManager
      attr_reader :ttl

      # rubocop:disable Metrics/ParameterLists
      def initialize(access_control, users: ENV['MXRB_USERS_JSON'],
                     tokens: ENV['MXRB_AUTH_TOKENS'], ttl: ENV.fetch('MXRB_SESSION_TTL', '3600'),
                     clock: -> { Time.now.utc }, store: nil)
        @access_control = access_control
        @users = parse_map(users, 'MXRB_USERS_JSON')
        @static_tokens = parse_map(tokens, 'MXRB_AUTH_TOKENS')
        @ttl = Integer(ttl)
        raise ArgumentError, 'session TTL must be positive' unless @ttl.positive?

        @clock = clock
        @store = store || Runtime::MemorySharedStore.new
      end
      # rubocop:enable Metrics/ParameterLists

      def anonymous
        @access_control.context
      end

      def authenticate(header)
        token = bearer_token(header)
        return anonymous unless token

        static = @static_tokens[token]
        return context_for(static) if static

        session = @store.read_session(token, now: @clock.call)
        raise AuthenticationError, 'invalid or expired bearer token' unless session

        context_for(session.identity)
      end

      def login(username, password)
        identity = authenticated_identity(username, password)

        token = SecureRandom.urlsafe_base64(32)
        csrf = SecureRandom.urlsafe_base64(32)
        expires_at = @clock.call + ttl
        profile = identity.slice('roles', 'user_roles', 'module_roles', 'attributes')
                          .merge('user' => username.to_s, '_csrf' => csrf)
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
        unless identity && password_matches?(identity, password)
          raise AuthenticationError, 'invalid username or password'
        end

        identity
      end

      def context_for(raw)
        value = raw.is_a?(Hash) ? raw : {}
        @access_control.context(
          user: value['user'], user_roles: value['roles'] || value['user_roles'],
          module_roles: value['module_roles'], attributes: value['attributes'] || {}
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
