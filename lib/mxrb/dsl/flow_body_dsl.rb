# frozen_string_literal: true

module Mxrb
  module Dsl
    # Shared activity DSL mixed into FlowBuilder, BranchBuilder, LoopBuilder, RescueBuilder
    module FlowBodyDsl
      CODE_ACTION_PARAMETER_KINDS = %i[
        entity entity_type microflow import_mapping export_mapping
      ].freeze
      REST_RESULT_HANDLING_TYPES = %i[mapping http_response string].freeze
      MAPPING_CONTENT_TYPES = %i[xml json].freeze

      def create_object(entity, as:, set: {}, commit: false, with_events: true,
                        refresh: false, &block)
        _acts << { type: :create_object, entity: entity.to_s, variable: as.to_s,
                   members: _build_members(set, &block), commit: commit,
                   with_events: with_events, refresh: refresh }
      end

      def change_object(variable, set: {}, commit: false, with_events: true,
                        refresh: false, &block)
        _acts << { type: :change_object, variable: variable.to_s,
                   members: _build_members(set, &block), commit: commit,
                   with_events: with_events, refresh: refresh }
      end

      def retrieve_objects(entity, as:, xpath: nil, limit: nil, single: false, sort: [])
        _acts << { type: :retrieve_objects, entity: entity.to_s, variable: as.to_s,
                   xpath: xpath&.to_s, limit: limit, single: single,
                   sortings: Array(sort) }
      end

      def retrieve_association(from, association:, as:)
        _acts << {
          type: :retrieve_association, variable: as.to_s,
          start_variable: from.to_s, association: association.to_s
        }
      end

      def commit(variable, with_events: true, refresh: false)
        _acts << {
          type: :commit, variable: variable.to_s,
          with_events: with_events, refresh: refresh
        }
      end

      def delete(variable, refresh: false)
        _acts << { type: :delete_object, variable: variable.to_s, refresh: refresh }
      end

      def call_microflow(name, as: nil, pass: nil, result_name: nil, use_return: nil, &block)
        mappings = _call_argument_mappings(pass, &block)
        _acts << {
          type: :call_microflow, name: name.to_s, variable: as&.to_s,
          result_name: result_name&.to_s,
          use_return: use_return.nil? ? !as.nil? : use_return == true,
          mappings: mappings
        }
      end

      def call_java(name, as: nil, pass: nil, result_name: nil, use_return: nil, &block)
        _acts << {
          type: :call_java, name: name.to_s,
          variable: as&.to_s, result_name: result_name&.to_s,
          use_return: use_return.nil? ? !as.nil? : use_return == true,
          mappings: _call_argument_mappings(pass, code_action: true, &block)
        }
      end

      %i[javascript nanoflow app_service].each do |runtime|
        define_method(:"call_#{runtime}") do |name, as: nil, pass: nil,
                                                result_name: nil, use_return: nil, &block|
          mappings = _call_argument_mappings(
            pass, code_action: runtime == :javascript, &block
          )
          _acts << {
            type: :"call_#{runtime}", name: name.to_s,
            variable: as&.to_s, result_name: result_name&.to_s,
            use_return: use_return.nil? ? !as.nil? : use_return == true,
            mappings: mappings
          }
        end
      end

      def create_variable(name, type: nil, value: nil)
        _acts << {
          type: :create_variable, variable: name.to_s,
          variable_type: type&.to_s, value: value
        }
      end

      def change_variable(name, to:)
        _acts << { type: :change_variable, variable: name.to_s, value: to }
      end

      def show_message(text = nil, type: :information, blocking: false,
                       translations: UNSET, parameters: UNSET, &block)
        if block
          unless translations.equal?(UNSET) && parameters.equal?(UNSET)
            raise ArgumentError, 'show_message accepts either translations:/parameters: or a block'
          end

          builder = FlowTextBuilder.new.evaluate(&block)
          translations = builder.translations
          parameters = builder.parameters
        else
          translations = nil if translations.equal?(UNSET)
          parameters = [] if parameters.equal?(UNSET)
        end
        _acts << {
          type: :show_message, text: text.to_s, message_type: type.to_s,
          blocking: blocking,
          translations: translations&.transform_keys(&:to_s),
          parameters: Array(parameters)
        }
      end

      def log_message(message, level: :info, node: nil, include_stack: false, parameters: [])
        _acts << {
          type: :log_message, message: message.to_s, level: level.to_s,
          node: node&.to_s, include_stack: include_stack,
          parameters: Array(parameters)
        }
      end

      def show_page(page, object: nil, location: nil, pass: UNSET, close_pages: nil,
                    title: nil, &block)
        if block
          unless pass.equal?(UNSET) && title.nil?
            raise ArgumentError, 'show_page accepts either pass:/title: or a block'
          end

          builder = FlowPageBuilder.new
          block.arity == 1 ? block.call(builder) : builder.instance_eval(&block)
          mappings = builder.mappings
          title = builder.title_translations
        else
          pass = {} if pass.equal?(UNSET)
          mappings = pass.map { |parameter, value| { parameter: parameter.to_s, value: value } }
        end
        _acts << {
          type: :show_page, page: page.to_s, variable: object&.to_s,
          location: location&.to_s,
          mappings: mappings,
          close_pages: close_pages, title: title
        }
      end

      def close_page(count: nil)
        _acts << { type: :close_page, count: count }
      end

      def show_home_page
        _acts << { type: :show_home_page }
      end

      def annotation(caption, position: '0;0', size: '200;80')
        _acts << {
          type: :annotation, caption: caption.to_s,
          position: position.to_s, size: size.to_s
        }
      end

      def as_node(reference)
        activity = _acts.last
        if activity.nil? || activity[:type] == :annotation_flow
          raise ArgumentError, 'as_node requires a preceding flow node declaration'
        end

        value = reference.to_s
        raise ArgumentError, 'flow node reference cannot be empty' if value.empty?

        _acts[-1] = activity.merge(node_ref: value)
      end

      def annotation_flow(from:, to:, origin_index: 1, destination_index: 0,
                          origin_vector: '0;0', destination_vector: '0;-30')
        origin = from.to_s
        destination = to.to_s
        raise ArgumentError, 'annotation_flow references cannot be empty' \
          if origin.empty? || destination.empty?

        _acts << {
          type: :annotation_flow, from: origin, to: destination,
          origin_index: Integer(origin_index), destination_index: Integer(destination_index),
          origin_vector: origin_vector.to_s, destination_vector: destination_vector.to_s
        }
      end

      def aggregate(list, function:, as:, attribute: nil)
        _acts << {
          type: :aggregate, variable: list.to_s, function: function.to_s,
          output: as.to_s, attribute: attribute.to_s
        }
      end

      def rollback(variable, refresh: false)
        _acts << { type: :rollback, variable: variable.to_s, refresh: refresh }
      end

      def cast(variable)
        _acts << { type: :cast, variable: variable.to_s }
      end

      def create_list(entity, as:)
        _acts << { type: :create_list, entity: entity.to_s, variable: as.to_s }
      end

      # `sort:` lists [attribute, direction] pairs for the Sort operation.
      def list_operation(operation, list, as:, with: nil, expression: nil, sort: nil)
        raise ArgumentError, 'sort: applies only to the sort list operation' if sort && operation.to_s != 'sort'

        _acts << {
          type: :list_operation, operation: operation.to_s,
          variable: list.to_s, second: with&.to_s,
          expression: expression&.to_s, output: as.to_s, sortings: sort && Array(sort)
        }
      end

      def change_list(list, action:, value:)
        _acts << {
          type: :change_list, variable: list.to_s,
          action: action.to_s, value: value
        }
      end

      def validation_feedback(variable, attribute: nil, association: nil,
                              translations: UNSET, parameters: UNSET, error: :rollback, &block)
        if block
          unless translations.equal?(UNSET) && parameters.equal?(UNSET)
            raise ArgumentError, 'validation_feedback accepts either translations:/parameters: or a block'
          end

          builder = FlowTextBuilder.new.evaluate(&block)
          translations = builder.translations
          parameters = builder.parameters
        else
          translations = {} if translations.equal?(UNSET)
          parameters = [] if parameters.equal?(UNSET)
        end
        _acts << {
          type: :validation_feedback, variable: variable.to_s,
          attribute: attribute.to_s, association: association.to_s,
          translations: translations.transform_keys(&:to_s),
          parameters: Array(parameters), error: error.to_s
        }
      end

      def call_rest(method:, location:, location_parameters: [], headers: UNSET,
                    username: nil, password: nil,
                    client_certificate: nil, proxy: nil,
                    request_mapping: nil, request_variable: nil,
                    request_body: nil, request_parameters: [],
                    result_mapping: nil, as: nil, result_entity: nil,
                    timeout: nil, commit: :yes_without_events,
                    result_handling: :mapping,
                    result_content_type: :json, force_single: false, single: false,
                    object_handling: :create, parameter_variable: nil,
                    error_result: :http_response, error: :rollback, &block)
        handling = result_handling.to_sym
        unless REST_RESULT_HANDLING_TYPES.include?(handling)
          raise ArgumentError, "unsupported REST result handling #{result_handling.inspect}"
        end
        raise ArgumentError, 'string REST result handling requires as' if
          handling == :string && as.to_s.empty?
        if handling == :string && (!result_entity.to_s.empty? || !result_mapping.to_s.empty?)
          raise ArgumentError, 'string REST result handling does not accept a result mapping or entity'
        end

        mapping_set = !request_mapping.to_s.empty?
        variable_set = !request_variable.to_s.empty?
        if mapping_set != variable_set
          raise ArgumentError, 'REST request mapping requires both request_mapping and request_variable'
        end
        if !request_body.nil? && mapping_set
          raise ArgumentError, 'call_rest accepts either a request body or a request mapping'
        end
        if username.to_s.empty? != password.to_s.empty?
          raise ArgumentError, 'REST basic authentication requires both username and password'
        end

        request_proxy_type, proxy_configuration = _rest_proxy(proxy)

        if block
          raise ArgumentError, 'call_rest accepts either headers: or a header block' unless headers.equal?(UNSET)

          headers = FlowRestBuilder.new.evaluate(&block).headers
        else
          headers = {} if headers.equal?(UNSET)
          headers = headers.transform_keys(&:to_s)
        end

        _acts << {
          type: :call_rest, method: method.to_s, location: location.to_s,
          location_parameters: Array(location_parameters),
          headers: headers,
          username: _optional_string(username), password: _optional_string(password),
          client_certificate: _optional_string(client_certificate),
          request_proxy_type:, proxy: proxy_configuration,
          request_mapping: request_mapping.to_s,
          request_variable: request_variable.to_s,
          request_body: _optional_string(request_body),
          request_parameters: Array(request_parameters),
          result_mapping: result_mapping.to_s, variable: as.to_s,
          result_entity: result_entity.to_s, timeout: timeout.to_s,
          commit: commit.to_s, result_handling: handling.to_s,
          result_content_type: result_content_type.to_s,
          force_single: force_single == true, single: single == true,
          object_handling: object_handling.to_s,
          parameter_variable: parameter_variable.to_s,
          error_result: error_result.to_s,
          error: error.to_s
        }
      end

      def execute_database_query(query = nil, as: nil, dynamic_query: nil,
                                 parameters: nil, connection_parameters: nil,
                                 error: :rollback, &block)
        if block
          if Array(parameters).any? || Array(connection_parameters).any?
            raise ArgumentError,
                  'database query mappings must use either keyword hashes or a block'
          end

          mappings = DatabaseQueryArgumentsBuilder.new
          mappings.instance_eval(&block)
          parameter_mappings = mappings.parameters
          connection_parameter_mappings = mappings.connection_parameters
        else
          parameter_mappings = (parameters || {}).map do |name, value|
            { name: name.to_s, value: value }
          end
          connection_parameter_mappings = (connection_parameters || {}).map do |name, value|
            { name: name.to_s, value: value }
          end
        end

        _acts << {
          type: :execute_database_query, query: query.to_s,
          dynamic_query: dynamic_query.to_s, variable: as&.to_s,
          parameters: parameter_mappings,
          connection_parameters: connection_parameter_mappings,
          error: error.to_s
        }
      end

      def import_xml(document, mapping:, as:, result_entity:, validate: false,
                     content_type: :xml, commit: :yes_without_events,
                     force_single: false, single: false, object_handling: :create,
                     parameter_variable: nil, error: :rollback)
        _acts << {
          type: :import_xml, variable: document.to_s, mapping: mapping.to_s,
          output: as.to_s, result_entity: result_entity.to_s,
          validate: validate == true, content_type: content_type.to_s,
          commit: commit.to_s, force_single: force_single == true,
          single: single == true, object_handling: object_handling.to_s,
          parameter_variable: parameter_variable.to_s, error: error.to_s
        }
      end

      def export_xml(variable, mapping:, as:, content_type: :xml, validate: false,
                     error: :rollback)
        content_type = content_type.to_sym
        unless MAPPING_CONTENT_TYPES.include?(content_type)
          raise ArgumentError, "unsupported export mapping content type #{content_type.inspect}"
        end
        if variable.to_s.empty? || mapping.to_s.empty? || as.to_s.empty?
          raise ArgumentError, 'export_xml requires variable, mapping, and as'
        end

        _acts << {
          type: :export_xml, variable: variable.to_s, mapping: mapping.to_s,
          output: as.to_s, content_type: content_type.to_s,
          validate: validate == true, error: error.to_s
        }
      end

      def download_file(variable, show_in_browser: false, error: :rollback)
        _acts << {
          type: :download_file, variable: variable.to_s,
          show_in_browser: show_in_browser == true, error: error.to_s
        }
      end

      def return_value(value)
        expression = value.is_a?(Symbol) ? "$#{value}" : value.to_s
        _acts << { type: :return_event, expression: expression }
      end

      def end_flow
        _acts << { type: :return_event, expression: '' }
      end

      def error_event
        _acts << { type: :error_event }
      end

      def continue_loop
        _acts << { type: :continue_event }
      end

      def break_loop
        raise ArgumentError, 'break_loop is only valid inside a loop' unless _break_allowed?

        _acts << { type: :break_event }
      end

      # rollback: true is Studio Pro's "Custom with rollback": the whole transaction
      # rolls back before the error flow runs.
      def rescue_all(rollback: false, &block)
        rescue_builder = RescueBuilder.new(allow_break: _break_allowed?)
        rescue_builder.instance_eval(&block) if block
        act = { type: :rescue_all, activities: rescue_builder.activities }
        act[:rollback] = true if rollback == true
        _acts << act
      end

      def decision(condition, &block)
        db = DecisionBuilder.new(
          condition.is_a?(Hash) ? condition : condition.to_s,
          allow_break: _break_allowed?
        )
        db.instance_eval(&block) if block
        _acts << db.to_h
      end

      def type_decision(variable, &block)
        builder = TypeDecisionBuilder.new(variable.to_s, allow_break: _break_allowed?)
        builder.instance_eval(&block) if block
        _acts << builder.to_h
      end

      def rule_decision(rule, &block)
        builder = RuleDecisionBuilder.new(rule, allow_break: _break_allowed?)
        if block
          block.arity == 1 ? block.call(builder) : builder.instance_eval(&block)
        end
        _acts << builder.to_h
      end

      def loop_over(variable, as: nil, &block)
        lb = LoopBuilder.new(variable.to_s, as: (as || variable).to_s)
        lb.instance_eval(&block) if block
        _acts << lb.to_h
      end

      def while_loop(condition, &block)
        lb = LoopBuilder.new(nil, as: nil)
        lb.instance_eval(&block) if block
        item = lb.to_h
        item[:type] = :while_loop
        item[:condition] = condition.to_s
        _acts << item
      end

      private

      def _call_argument_mappings(pass, code_action: false, &block)
        _validate_call_argument_notation!(pass, block)
        return _block_call_argument_mappings(code_action, &block) if block
        return _code_action_mappings(pass || {}) if code_action

        (pass || {}).map { |param, value| { param: param.to_s, value: value } }
      end

      def _validate_call_argument_notation!(pass, block)
        return unless block && pass && !pass.empty?

        raise ArgumentError, 'call arguments must use either pass: or a block'
      end

      def _block_call_argument_mappings(code_action, &block)
        builder = CallArgumentsBuilder.new(code_action: code_action)
        builder.instance_eval(&block)
        builder.mappings
      end

      def _code_action_mappings(pass)
        pass.map do |parameter, value|
          if value.is_a?(Hash) && value.key?(:kind)
            kind = value.fetch(:kind).to_sym
            unless CODE_ACTION_PARAMETER_KINDS.include?(kind)
              raise ArgumentError, "unsupported code action parameter kind #{kind.inspect}"
            end
          end
          { param: parameter.to_s, value: value }
        end
      end

      def _optional_string(value)
        value&.to_s
      end

      def _rest_proxy(proxy)
        return ['DefaultProxy', nil] if proxy.nil?

        if proxy.is_a?(String) || proxy.is_a?(Symbol)
          return ['DefaultProxy', nil] if proxy.to_sym == :default
          return ['NoProxy', nil] if %i[none no_proxy].include?(proxy.to_sym)
        end

        raise ArgumentError, 'REST proxy must be :default, :none, or a configuration hash' unless proxy.is_a?(Hash)

        values = proxy.transform_keys(&:to_sym)
        unknown = values.keys - %i[id host port username password use]
        raise ArgumentError, "unsupported REST proxy options: #{unknown.join(', ')}" unless unknown.empty?
        if values[:host].to_s.empty? || values[:port].to_s.empty?
          raise ArgumentError, 'REST proxy override requires host and port expressions'
        end
        if values[:username].to_s.empty? != values[:password].to_s.empty?
          raise ArgumentError, 'REST proxy authentication requires both username and password'
        end

        configuration = {
          id: _optional_string(values[:id]), host: values[:host].to_s, port: values[:port].to_s,
          username: values[:username].to_s, password: values[:password].to_s,
          use: values.fetch(:use, 'true').to_s
        }
        ['Override', configuration]
      rescue NoMethodError
        raise ArgumentError, 'REST proxy must be :default, :none, or a configuration hash'
      end

      def _break_allowed? = false

      def _build_members(set_hash, &block)
        if block
          sb = SetBuilder.new
          sb.instance_eval(&block)
          sb.members
        else
          set_hash.map { |k, v| { attribute: k.to_s, value: v } }
        end
      end
    end
  end
end
