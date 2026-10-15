# frozen_string_literal: true

module Mxrb
  module Runtime
    # An exception a Java action throws: $latestError/ErrorType is its Java class.
    class JavaActionError < NativeRuntimeError
      attr_reader :java_class

      def initialize(java_class, message)
        @java_class = java_class
        super(message.to_s)
      end
    end

    # What a context-bound Java action adapter may use of the microflow that calls
    # it: the parts of IContext and Core that audited Marketplace actions rely on.
    class JavaActionContext # rubocop:disable Metrics/ClassLength
      FILE_CONTENT = 'SELECT content FROM mxrb_file_contents WHERE entity = ? AND object_id = ?'
      MESSAGE_LEVELS = { 'INFO' => 'information', 'WARNING' => 'warning', 'ERROR' => 'error' }.freeze
      # The members an entity has when it stores who and when created and changed it.
      SYSTEM_MEMBERS = { 'createdDate' => :attribute, 'changedDate' => :attribute,
                         'owner' => :reference, 'changedBy' => :reference }.freeze
      LOG_LEVELS = %w[Trace Debug Info Warning Error Critical].freeze

      attr_reader :store, :security_context, :project

      def initialize(interpreter:, store:, log:, project:, flows:, security_context: nil, policy: nil, # rubocop:disable Metrics/ParameterLists
                     environment: ENV, constants: nil)
        @interpreter = interpreter
        @store = store
        @log = log
        @project = project
        @flows = flows
        @security_context = security_context
        @policy = policy
        @environment = environment
        @constants = constants || Constants.new(project, environment:)
      end

      # IMendixObject.getValue: a calculated attribute runs its microflow.
      def value(object, name)
        value = @interpreter.calculated_value(object, name, context: @security_context)
        value.equal?(Native::Expression::STORED) ? object.members[name] : value
      end

      # The value of a constant (Core.getConfiguration().getConstantValue).
      def constant(name) = @constants.value(name)

      def log(node, level, message)
        level = level.to_s
        raise ArgumentError, "unknown log level #{level.inspect}" unless LOG_LEVELS.include?(level)

        @log << "#{node} #{level}: #{message}"
        nil
      end

      def flow?(name) = @flows.include?(name.to_s)

      # Core.microflowCall(name).withParams(arguments).execute(context), optionally
      # as another user; like Misc.getContextFor, the caller's own name keeps the context.
      def call_flow(name, arguments = {}, username: nil, sudo: false)
        raise ArgumentError, "microflow not found: #{name}" unless flow?(name)

        context = username.nil? ? @security_context : context_for(username, sudo)
        @interpreter.call(name.to_s, arguments.to_h, context:)
      end

      def end_transaction = @interpreter.end_transaction

      # Core.retrieveXPathQuery: "//Module.Entity[constraint]", narrowed and
      # sorted as the calling microflow's retrieves are.
      def retrieve(xpath, variables = {}, offset: 0, amount: -1, sort: [])
        match = %r{\A//([A-Za-z_]\w*\.[A-Za-z_]\w*)(.*)\z}m.match(xpath.to_s.strip)
        raise ArgumentError, "unsupported XPath query #{xpath.inspect}" unless match

        @interpreter.retrieve_xpath(match[1], match[2], variables, offset:, amount:, sort:)
      end

      # What a member of an entity, or of its generalizations, is: :integer for
      # an Integer attribute, :attribute for another one, :reference or
      # :reference_set for an association; nil when the entity has no such member.
      # Members of System entities are those the Mendix 11.12.1 Runtime reports.
      def member_kind(entity_name, name) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity
        name = name.to_s
        chain, root = generalizations(entity_name)
        attribute = chain.flat_map(&:attributes).find { _1.name == name }
        return attribute.type == :integer ? :integer : :attribute if attribute

        association = @project.modules.flat_map(&:associations).find { _1.name == name }
        return association.association_type.to_s == 'ReferenceSet' ? :reference_set : :reference if association

        SYSTEM_MEMBERS.fetch(name) { system_member_kind(root, name) }
      end

      # A message the client shows, as a show-message activity of the calling microflow would.
      def show_message(type, message, blocking: false)
        level = MESSAGE_LEVELS.fetch(type.to_s) { raise ArgumentError, "unknown message type #{type.inspect}" }
        @interpreter.effects << { type: 'show_message', level:, blocking:, message: message.to_s }
        nil
      end

      # IContext.getSession: its id, its System.User and that user's name, or a guest's
      # (anonymous) session; without a session, the system's.
      def session
        attributes = @security_context.respond_to?(:attributes) ? @security_context.attributes : {}
        id = attributes['session_id']
        user = current_user
        anonymous = attributes['anonymous'] == true
        name = user ? user.members['Name'] : ("Anonymous_#{id}" if anonymous)
        { 'id' => id, 'user' => user, 'name' => name, 'anonymous' => anonymous }
      end

      # Core.getDefaultLanguage: the project's default language and its System.Language.
      def default_language
        code = Languages.settings(@project)['default'].to_s
        code = 'en_US' if code.empty?
        { 'code' => code, 'language' => @store.retrieve(Languages::LANGUAGE).find { _1.members['Code'] == code } }
      end

      # The System.User of the calling session (IContext.getSession().getUser()).
      def user = current_user

      def changed?(object) = @store.respond_to?(:changed?) ? @store.changed?(object) : true

      # Core.getFileDocumentContent: the stored bytes of a System.FileDocument.
      def file_content(object)
        database = @store.database if @store.respond_to?(:database)
        content = database&.get_first_value(FILE_CONTENT, [object.entity, object.id])
        raise NativeRuntimeError, "#{object.entity} #{object.id} has no file contents" if content.nil?

        content.to_s.b
      end

      # Core.getConfiguration().getApplicationRootUrl(): MXRB_APPLICATION_ROOT_URL,
      # else the address the exported Ruby server binds to.
      def application_root_url
        @environment.fetch('MXRB_APPLICATION_ROOT_URL') do
          "http://#{@environment.fetch('HOST', 'localhost')}:#{@environment.fetch('MXRB_SERVER_PORT', '9292')}/"
        end
      end

      # The primitive attributes of an entity and its generalizations as
      # [name, type, calculated] (IMetaObject.getMetaPrimitives).
      def attributes(entity_name)
        chain, root = generalizations(entity_name)
        raise NativeRuntimeError, "unknown entity #{entity_name}" if chain.empty?

        inherited_system_attributes(root) + chain.reverse.flat_map do |entity|
          entity.attributes.map { [_1.name, _1.type, calculated?(_1)] }
        end
      end

      def runtime_version = @project.mendix_version.to_s
      def model_version = @environment.fetch('MXRB_MODEL_VERSION', 'unversioned')

      private

      # The entity and its generalizations, most specific first, and the first
      # generalization outside the model (System.User, say) or ''.
      def generalizations(entity_name)
        entities = @project.modules.flat_map { |mod| mod.entities.map { ["#{mod.name}.#{_1.name}", _1] } }.to_h
        chain = []
        current = entity_name.to_s
        while (entity = entities[current]) && !chain.include?(entity)
          chain << entity
          current = entity.respond_to?(:generalization_target) ? entity.generalization_target.to_s : ''
        end
        [chain, current]
      end

      # A member of a System entity, or of one of its System generalizations.
      def system_member_kind(entity, name)
        objects = Native.system_metamodel.fetch('objects').to_h { [_1.fetch('name'), _1] }
        return nil unless objects.key?(entity)

        entities = [entity, *objects.fetch(entity).fetch('supers')]
        primitive = entities.flat_map { objects.fetch(_1).fetch('primitives') }.find { _1.fetch('name') == name }
        return primitive.fetch('type') == 'Integer' ? :integer : :attribute if primitive

        system_association_kind(entities, name)
      end

      def system_association_kind(entities, name)
        association = Native.system_metamodel.fetch('associations').find do
          entities.include?(_1.fetch('parent')) && _1.fetch('name').split('.').last == name
        end
        association && (association.fetch('type') == 'REFERENCESET' ? :reference_set : :reference)
      end

      def context_for(username, sudo) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        name = username.to_s
        raise ArgumentError, 'Assertion: No username provided' if name.empty?

        current = current_user
        return @security_context if current && current.members['Name'].to_s == name

        user = SystemDomain.find_user(@store, name)
        raise ArgumentError, "Assertion: user not found: #{name}" unless user

        roles = @store.retrieve_association('UserRoles', user).map { _1.members['Name'] }
        attributes = (@security_context.respond_to?(:attributes) ? @security_context.attributes : {})
                     .merge('sudo' => sudo == true)
        options = { user: user.id, user_roles: roles, attributes: }
        @policy ? @policy.context(**options) : SecurityContext.new(**options)
      end

      def inherited_system_attributes(name)
        return [] if name.empty? || !name.start_with?('System.')
        unless name == SystemDomain::USER
          raise NativeRuntimeError, "attributes of #{name} specializations are not supported"
        end

        SystemDomain::ATTRIBUTES.fetch(name).map { |attribute, type,| [attribute, type, false] }
      end

      def calculated?(attribute) = attribute.respond_to?(:calculated) && !attribute.calculated.nil?

      def current_user
        id = @security_context.respond_to?(:user) && @security_context.user
        id.is_a?(String) ? @store.find(SystemDomain::USER, id) : nil
      end
    end
  end
end
