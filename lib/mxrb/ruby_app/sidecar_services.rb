# frozen_string_literal: true

require 'base64'

module Mxrb
  module RubyApp
    # What the Java actions sidecar asks of the application beyond its objects:
    # the metamodel behind Core.getMetaObjects and the microflow API, enumeration
    # captions, and the contents a Java action stores in a file document.
    class SidecarServices
      # The paths of the requests a Java action asked the server to forward.
      attr_reader :request_handlers

      # sessions gives the application's SessionManager, for guest sessions.
      def initialize(project, sessions: nil)
        @project = project
        @sessions = sessions
        @request_handlers = []
      end

      def metamodel
        model = Metamodel.new(@project)
        { 'objects' => model.objects, 'associations' => model.associations, 'microflows' => model.microflows }
      end

      # A value's caption in a language, '' when it has none there, as the Runtime
      # answers; without a language, the caption in the first language declared.
      def caption(enumeration, value, language)
        implementation = Registry.fetch(:enumeration, enumeration)
        return system_caption(enumeration, value) unless implementation

        captions = implementation.values.find { _1.fetch(:name) == value }&.fetch(:captions) || {}
        language.nil? ? captions.values.first.to_s : captions.fetch(language, '')
      end

      # Core.storeFileDocumentContent: the contents, the name, and the members
      # a file document reports for them.
      def store_file(store, object, name, bytes)
        file = FileContent.new(store.database).write(object.entity, object.id, name, Base64.strict_encode64(bytes))
        object.members.merge!('Name' => file.fetch(:name), 'HasContents' => true, 'Size' => file.fetch(:size))
        store.touch(object)
      end

      # Core.addRequestHandler; the server keeps /api to itself.
      def register_request_handler(path)
        key = path.to_s.gsub(%r{\A/+|/+\z}, '')
        if key.empty? || key.match?(%r{\Aapi(/|\z)})
          raise ArgumentError, "request handler path #{path.inspect} is reserved"
        end

        @request_handlers |= [key]
      end

      # The registered handler for a request path: the longest that prefixes it.
      def request_handler(path)
        @request_handlers.select { path == "/#{_1}" || path.start_with?("/#{_1}/") }.max_by(&:length)
      end

      # Core.initializeGuestSession: a session of the guest user role, when the
      # application's security lets guests in.
      def guest_session
        raise NativeRuntimeError, 'guest access is disabled' unless guest_login_enabled?

        token = @sessions.call.guest([security.fetch(:guest_user_role)])
        { 'id' => token, 'user' => nil, 'name' => "Anonymous_#{token}", 'anonymous' => true }
      end

      def guest_login_enabled? = security[:guest_access_enabled] == true

      # Core.initializeSession: a session of a System.User under its user roles.
      def user_session(store, user)
        roles = store.retrieve_association('UserRoles', user).map { _1.members['Name'] }
        { 'id' => @sessions.call.open(user, roles), 'user' => user, 'name' => user.members['Name'].to_s,
          'anonymous' => false }
      end

      # The administrator Configuration.getAdminUserName and getAdminUserRoleName report.
      def project_security
        { 'admin_user_name' => security[:admin_user_name].to_s, 'admin_user_role' => security[:admin_user_role].to_s }
      end

      private

      def security = Registry.all(:project_security).values.first&.native_definition || {}

      def system_caption(enumeration, value)
        values = Runtime::SystemMetamodel.enumerations(@project.mendix_version).fetch(enumeration, [])
        values.find { _1.fetch('id') == value }&.fetch('caption').to_s
      end
    end
  end
end
