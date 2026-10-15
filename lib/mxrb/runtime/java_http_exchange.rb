# frozen_string_literal: true

module Mxrb
  module Runtime
    # What the Java actions sidecar shares with the HTTP request an action runs for.
    class JavaSidecar
      # The HTTP request a published REST operation runs for, which its Java actions
      # get from IContext.getRuntimeRequest, and the responses they wrote through
      # IContext.getRuntimeResponse: each with its headers and cookies.
      HttpExchange = Struct.new(:request, :responses) do
        def initialize(request) = super(request, [])

        # The headers the Java actions added, a cookie as its Set-Cookie header.
        def headers
          responses.flat_map do |response|
            response.fetch('headers').map { |name, value| [name, value] } +
              response.fetch('cookies').map { ['Set-Cookie', JavaSidecar.cookie_header(_1)] }
          end
        end
      end

      # A cookie a Java action set, as the Set-Cookie header the server sends.
      def self.cookie_header(cookie, secure: ENV['MXRB_SECURE_COOKIES'] == 'true')
        attributes = ["#{cookie.fetch('name')}=#{cookie.fetch('value')}", "Path=#{cookie.fetch('path') || '/'}",
                      'SameSite=Lax']
        attributes << "Max-Age=#{cookie['max_age']}" if cookie['max_age'].to_i >= 0
        attributes << 'HttpOnly' if cookie['http_only']
        attributes << 'Secure' if secure
        attributes.join('; ')
      end
    end
  end
end
