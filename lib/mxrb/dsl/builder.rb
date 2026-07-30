# frozen_string_literal: true

require "digest"
require "json"
require "base64"

module Mxrb
  module Dsl
    # Shared widget-building methods for PageBuilder and ContainerBuilder.
    # Includers must implement private `_widget_list` returning the target array.
    module WidgetDsl
      def text_box(name, attribute: nil, caption: nil, &block)
        _add_widget(:text_box, name, attribute: attribute, caption: caption, &block)
      end

      def number_input(name, attribute: nil, caption: nil, &block)
        _add_widget(:number_input, name, attribute: attribute, caption: caption, &block)
      end

      def check_box(name, attribute: nil, caption: nil, &block)
        _add_widget(:check_box, name, attribute: attribute, caption: caption, &block)
      end

      def date_picker(name, attribute: nil, caption: nil, &block)
        _add_widget(:date_picker, name, attribute: attribute, caption: caption, &block)
      end

      def reference_selector(name, attribute: nil, caption: nil, &block)
        _add_widget(:reference_selector, name, attribute: attribute, caption: caption, &block)
      end

      def text(name, caption: nil, &block)
        _add_widget(:text, name, caption: caption || name.to_s, &block)
      end

      def data_grid(name, entity: nil, &block)
        _add_widget(:data_grid, name, entity: entity, &block)
      end

      def tab_control(name, &block)
        _add_widget(:tab_control, name, &block)
      end

      def button(name, caption: nil, &block)
        _add_widget(:button, name, caption: caption || name.to_s, &block)
      end

      def drop_down(name, attribute: nil, caption: nil)
        _widget_list << {
          type: :drop_down, name: name.to_s,
          options: { attribute: attribute&.to_s, caption: caption }.compact,
          events: []
        }
      end

      def snippet(name, from: nil)
        _widget_list << {
          type: :snippet, name: name.to_s,
          options: { snippet: (from || name).to_s },
          events: []
        }
      end

      def container(name, class_name: nil, &block)
        cb = ContainerBuilder.new(name, class_name: class_name)
        cb.instance_eval(&block) if block
        _widget_list << cb.to_h
      end

      private

      def _add_widget(type, name, **options, &block)
        builder = WidgetBuilder.new(type, name, **options)
        builder.instance_eval(&block) if block
        _widget_list << builder.to_h
      end
    end

    # Builds sub-widgets inside a data_grid column sub-items or inside a container.
    class WidgetBuilder
      def initialize(type, name, **options)
        @type        = type
        @name        = name.to_s
        @options     = options
        @events      = []
        @columns     = []
        @tabs        = []
        @search_bar  = nil
        @toolbar     = nil
      end

      def column(name, attribute: nil, caption: nil)
        @columns << { name: name.to_s, attribute: attribute&.to_s, caption: caption }.compact
      end

      def tab_page(name, caption: nil)
        @tabs << { name: name.to_s, caption: caption || name.to_s }
      end

      def search_bar(&block)
        sb = SearchBarBuilder.new
        sb.instance_eval(&block) if block
        @search_bar = sb.to_h
      end

      def toolbar(&block)
        tb = ToolbarBuilder.new
        tb.instance_eval(&block) if block
        @toolbar = tb.to_h
      end

      %i[on_change on_click on_enter on_leave].each do |event|
        define_method(event) do |microflow: nil, nanoflow: nil, action: nil|
          choices = { microflow: microflow, nanoflow: nanoflow, action: action }.compact
          raise ArgumentError, "#{event} requires exactly one handler" unless choices.size == 1
          @events << { event: event, kind: choices.keys.first, handler: choices.values.first.to_s }
        end
      end

      def to_h
        options = @options.dup
        options[:columns]    = @columns    unless @columns.empty?
        options[:tabs]       = @tabs       unless @tabs.empty?
        options[:search_bar] = @search_bar if @search_bar
        options[:toolbar]    = @toolbar    if @toolbar
        { type: @type, name: @name, options: options, events: @events }
      end
    end

    class SearchBarBuilder
      def initialize
        @fields = []
      end

      def search_field(attribute, caption: nil)
        @fields << { attribute: attribute.to_s, caption: caption }
      end

      def to_h
        { fields: @fields }
      end
    end

    class ToolbarBuilder
      def initialize
        @buttons = []
      end

      def new_button(caption: "New")
        @buttons << { type: :new, caption: caption }
      end

      def delete_button(caption: "Delete")
        @buttons << { type: :delete, caption: caption }
      end

      def search_button(caption: "Search")
        @buttons << { type: :search, caption: caption }
      end

      def export_button(caption: "Export")
        @buttons << { type: :export, caption: caption }
      end

      def to_h
        { buttons: @buttons }
      end
    end

    # Builds nested widgets inside a container widget.
    class ContainerBuilder
      include WidgetDsl

      def initialize(name, class_name: nil)
        @name       = name.to_s
        @class_name = class_name&.to_s
        @children   = []
      end

      def to_h
        opts = {}
        opts[:class] = @class_name if @class_name && !@class_name.empty?
        { type: :container, name: @name, options: opts, children: @children, events: [] }
      end

      private

      def _widget_list = @children
    end

    # Entry point for the project-definition DSL.
    # Used by Mxrb.define { ... }
    class Builder
      def initialize(path)
        @path              = path
        @mendix_version    = "10.18.0"
        @modules           = []
        @security          = nil
        @native_units_path = nil
        @native_unit_overrides = []
      end

      def mendix_version(v)
        @mendix_version = v
      end

      def module(name, &block)
        mod = ModuleBuilder.new(name)
        mod.instance_eval(&block) if block
        @modules << mod
      end

      def security(&block)
        builder = SecurityBuilder.new
        builder.instance_eval(&block) if block
        @security = builder.to_h
      end

      def native_units(path)
        @native_units_path = path
      end

      def native_unit(unit_id, container_id:, containment:, deep_structure:, module_name: nil)
        raise ArgumentError, "deep_structure requires a Hash" unless deep_structure.is_a?(Hash)

        @native_unit_overrides << {
          unit_id: unit_id.to_s,
          container_id: container_id.to_s,
          containment: containment.to_s,
          module: module_name&.to_s,
          doc: deep_structure
        }
      end

      def bson_binary(base64, subtype: :generic)
        BSON::Binary.new(Base64.strict_decode64(base64), subtype)
      end

      def evaluate(path)
        instance_eval(File.read(path), path, 1)
      end

      def build!
        validate!
        Writer.new(@path, definition).write!
        self
      end

      def graph
        Architecture::Graph.new(definition)
      end

      def validate!
        Architecture::Validator.new(graph).validate!
      end

      def definition
        {
          version: @mendix_version,
          modules: @modules.map(&:to_h),
          security: @security,
          native_units_path: @native_units_path,
          native_unit_overrides: @native_unit_overrides
        }
      end
    end

    class SecurityBuilder
      def initialize
        @user_roles = []
        @security_level = nil
      end

      # Mendix stores the project security mode as an enum-like string such as
      # "CheckNothing" or "CheckEverything". Keep the native value explicit so
      # export/import does not silently weaken project security.
      def security_level(value)
        @security_level = value.to_s
      end

      def user_role(name, module_roles: [], admin: false)
        @user_roles << {
          name: name.to_s,
          module_roles: Array(module_roles).map(&:to_s),
          admin: admin
        }
      end

      def to_h
        { user_roles: @user_roles, security_level: @security_level }
      end
    end

    class EnumerationBuilder
      attr_reader :name

      def initialize(name)
        @name   = name.to_s
        @values = []
        @doc    = ""
      end

      def value(name, caption: nil)
        @values << { name: name.to_s, caption: caption&.to_s }
      end

      def documentation(d) = (@doc = d)

      def to_h
        { name: @name, values: @values, documentation: @doc }
      end
    end

    class ConstantBuilder
      CONSTANT_TYPES = {
        string: "DataTypes$StringType", integer: "DataTypes$IntegerType",
        boolean: "DataTypes$BooleanType", decimal: "DataTypes$DecimalType",
        datetime: "DataTypes$DateTimeType"
      }.freeze

      attr_reader :name

      def initialize(name, type:, value: nil)
        @name  = name.to_s
        @type  = type.to_sym
        @value = value
        @doc   = ""
      end

      def documentation(d) = (@doc = d)

      def to_h
        { name: @name, type: @type, value: @value, documentation: @doc }
      end
    end

    class ScheduledEventBuilder
      INTERVAL_UNITS = {
        milliseconds: "Millisecond", seconds: "Second", minutes: "Minute",
        hours: "Hour", days: "Day", weeks: "Week", months: "Month", years: "Year"
      }.freeze

      attr_reader :name

      def initialize(name, microflow:, interval: 1, unit: :days, enabled: true)
        @name      = name.to_s
        @microflow = microflow.to_s
        @interval  = interval.to_i
        @unit      = unit.to_sym
        @enabled   = enabled
        @doc       = ""
      end

      def documentation(d) = (@doc = d)

      def to_h
        {
          name: @name, microflow: @microflow, interval: @interval,
          unit: @unit, enabled: @enabled, documentation: @doc
        }
      end
    end

    class ModuleBuilder
      attr_reader :name, :entities, :pages, :microflows, :nanoflows, :repositories,
                  :associations, :menus, :module_roles, :enumerations, :constants,
                  :scheduled_events

      def initialize(name)
        @name             = name.to_s
        @entities         = []
        @pages            = []
        @microflows       = []
        @nanoflows        = []
        @repositories     = []
        @associations     = []
        @menus            = []
        @module_roles     = []
        @enumerations     = []
        @constants        = []
        @scheduled_events = []
      end

      def entity(name, &block)
        eb = EntityBuilder.new(name)
        eb.instance_eval(&block) if block
        @entities << eb.to_h
      end

      def page(name, &block)
        pb = PageBuilder.new(name)
        pb.instance_eval(&block) if block
        @pages << pb.to_h
      end

      def menu(name, &block)
        mb = MenuBuilder.new(name)
        mb.instance_eval(&block) if block
        @menus << mb.to_h
      end

      def module_role(name, description: "")
        @module_roles << { name: name.to_s, description: description.to_s }
      end

      def microflow(name, kind: :use_case, public: false, &block)
        fb = FlowBuilder.new(name, runtime: :server, kind: kind, public: public)
        fb.instance_eval(&block) if block
        @microflows << fb.to_h
      end

      def nanoflow(name, public: false, &block)
        fb = FlowBuilder.new(name, runtime: :client, kind: :client_action, public: public)
        fb.instance_eval(&block) if block
        @nanoflows << fb.to_h
      end

      def query(name, public: false, &block)
        microflow(name, kind: :query, public: public, &block)
      end

      def repository(name, implementation: nil, public: false)
        @repositories << { name: name.to_s, implementation: implementation&.to_s, public: public }
      end

      def enumeration(name, &block)
        eb = EnumerationBuilder.new(name)
        eb.instance_eval(&block) if block
        @enumerations << eb.to_h
      end

      def constant(name, type:, value: nil, &block)
        cb = ConstantBuilder.new(name, type: type, value: value)
        cb.instance_eval(&block) if block
        @constants << cb.to_h
      end

      def scheduled_event(name, microflow:, interval: 1, unit: :days, enabled: true, &block)
        sb = ScheduledEventBuilder.new(
          name, microflow: microflow, interval: interval, unit: unit, enabled: enabled
        )
        sb.instance_eval(&block) if block
        @scheduled_events << sb.to_h
      end

      def evaluate(path)
        instance_eval(File.read(path), path, 1)
      end

      def to_h
        {
          name: @name, entities: @entities, pages: @pages,
          microflows: @microflows, nanoflows: @nanoflows,
          repositories: @repositories, menus: @menus, module_roles: @module_roles,
          enumerations: @enumerations, constants: @constants,
          scheduled_events: @scheduled_events
        }
      end
    end

    class MenuBuilder
      def initialize(name)
        @name  = name.to_s
        @items = []
        @deep_structure = nil
      end

      def deep_structure(value)
        raise ArgumentError, "deep_structure requires a Hash" unless value.is_a?(Hash)

        @deep_structure = value
      end

      def bson_binary(base64, subtype: :generic)
        BSON::Binary.new(Base64.strict_decode64(base64), subtype.to_sym)
      end

      def item(caption, page: nil, &block)
        child = self.class.new(caption)
        child.instance_eval(&block) if block
        @items << { caption: caption.to_s, page: page&.to_s, items: child.items }.compact
      end

      def items = @items

      def to_h
        { name: @name, items: @items, deep_structure: @deep_structure }
      end
    end

    class EntityBuilder
      ATTR_TYPES = %i[string integer long float decimal boolean datetime autonumber hashstring binary enum].freeze

      attr_reader :name

      def initialize(name)
        @name         = name.to_s
        @attributes   = []
        @persistable  = true
        @doc          = ""
        @associations = []
        @lifecycle    = nil
        @access_rules = nil
      end

      ATTR_TYPES.each do |type|
        define_method(type) do |attr_name, **opts|
          @attributes << { name: attr_name.to_s, type: type, **opts }
        end
      end

      def non_persistent!  = (@persistable = false)
      def documentation(d) = (@doc = d)

      def association(target, type: :Reference, name: nil)
        @associations << {
          name: (name || "#{@name}_#{target}").to_s,
          target: target.to_s,
          type: type.to_sym
        }
      end

      %i[before_commit after_commit before_delete after_delete].each do |event|
        define_method(event) do |microflow:|
          @lifecycle ||= []
          @lifecycle << { event: event, handler: microflow.to_s }
        end
      end

      # access_rule "Module.Role", create: true, delete: false, read: :all, write: [:Name]
      def access_rule(*roles, create: false, delete: false, read: :none, write: :none, xpath: "")
        @access_rules ||= []
        @access_rules << {
          roles: roles.map(&:to_s),
          create: create,
          delete: delete,
          read: normalize_access(read),
          write: normalize_access(write),
          xpath: xpath.to_s
        }
      end

      def to_h
        {
          name: @name, persistable: @persistable, documentation: @doc,
          attributes: @attributes, associations: @associations, lifecycle: @lifecycle,
          access_rules: @access_rules
        }
      end

      private

      def normalize_access(value)
        case value
        when :all, :none then value
        when Array       then value.map(&:to_s)
        else value.to_sym
        end
      end
    end

    class PageBuilder
      include WidgetDsl

      def initialize(name)
        @name          = name.to_s
        @layout        = "Atlas_Default"
        @title         = name.to_s
        @popup         = false
        @data_source   = nil
        @events        = []
        @widgets       = []
        @allowed_roles = nil
        @deep_structure = nil
      end

      def layout(l) = (@layout = l)
      def title(t)  = (@title = t)
      def popup!    = (@popup = true)

      # Full, editable Mendix page payload for structures without a concise
      # typed DSL yet (layout grids, custom widgets, list views, etc.).
      def deep_structure(value)
        raise ArgumentError, "deep_structure requires a Hash" unless value.is_a?(Hash)

        @deep_structure = value
      end

      def bson_binary(base64, subtype: :generic)
        BSON::Binary.new(Base64.strict_decode64(base64), subtype.to_sym)
      end

      def allowed_roles(*roles)
        @allowed_roles = roles.map(&:to_s)
      end

      def data_source(query: nil, microflow: nil, nanoflow: nil)
        choices = { microflow: microflow || query, nanoflow: nanoflow }.compact
        raise ArgumentError, "data_source requires exactly one target" unless choices.size == 1
        @data_source = { kind: choices.keys.first, name: choices.values.first.to_s }
      end

      %i[on_change on_click on_submit on_load].each do |event|
        define_method(event) do |target: nil, microflow: nil, nanoflow: nil, action: nil|
          choices = { microflow: microflow, nanoflow: nanoflow, action: action }.compact
          raise ArgumentError, "#{event} requires exactly one handler" unless choices.size == 1
          @events << {
            event: event, target: target&.to_s,
            kind: choices.keys.first, handler: choices.values.first.to_s
          }
        end
      end

      def to_h
        {
          name: @name, layout: @layout, title: @title, popup: @popup,
          data_source: @data_source, events: @events, widgets: @widgets,
          allowed_roles: @allowed_roles, deep_structure: @deep_structure
        }
      end

      private

      def _widget_list = @widgets
    end

    # Shared activity DSL mixed into FlowBuilder, BranchBuilder, LoopBuilder, RescueBuilder
    module FlowBodyDsl
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

      def call_microflow(name, as: nil, pass: {}, result_name: nil, use_return: nil)
        mappings = pass.map { |param, var| { param: param.to_s, value: var } }
        _acts << {
          type: :call_microflow, name: name.to_s, variable: as&.to_s,
          result_name: result_name&.to_s,
          use_return: use_return.nil? ? !as.nil? : use_return == true,
          mappings: mappings
        }
      end

      %i[java javascript nanoflow app_service].each do |runtime|
        define_method(:"call_#{runtime}") do |name, as: nil, pass: {},
                                                result_name: nil, use_return: nil|
          mappings = pass.map { |param, value| { param: param.to_s, value: value } }
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
                       translations: nil, parameters: [])
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

      def show_page(page, object: nil, location: nil, pass: {}, close_pages: nil,
                    title: nil)
        _acts << {
          type: :show_page, page: page.to_s, variable: object&.to_s,
          location: location&.to_s,
          mappings: pass.map { |parameter, value| { parameter: parameter.to_s, value: value } },
          close_pages: close_pages, title: title
        }
      end

      def close_page(count: nil)
        _acts << { type: :close_page, count: count }
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

      def list_operation(operation, list, with:, as:)
        _acts << {
          type: :list_operation, operation: operation.to_s,
          variable: list.to_s, second: with.to_s, output: as.to_s
        }
      end

      def change_list(list, action:, value:)
        _acts << {
          type: :change_list, variable: list.to_s,
          action: action.to_s, value: value
        }
      end

      def validation_feedback(variable, attribute: nil, association: nil,
                              translations: {}, parameters: [], error: :rollback)
        _acts << {
          type: :validation_feedback, variable: variable.to_s,
          attribute: attribute.to_s, association: association.to_s,
          translations: translations.transform_keys(&:to_s),
          parameters: Array(parameters), error: error.to_s
        }
      end

      def call_rest(method:, location:, location_parameters: [], headers: {},
                    request_mapping: nil, request_variable: nil,
                    result_mapping: nil, as: nil, result_entity: nil,
                    timeout: nil, commit: :yes_without_events,
                    error_result: :http_response, error: :rollback)
        _acts << {
          type: :call_rest, method: method.to_s, location: location.to_s,
          location_parameters: Array(location_parameters),
          headers: headers.transform_keys(&:to_s),
          request_mapping: request_mapping&.to_s,
          request_variable: request_variable&.to_s,
          result_mapping: result_mapping&.to_s, variable: as&.to_s,
          result_entity: result_entity&.to_s, timeout: timeout&.to_s,
          commit: commit.to_s, error_result: error_result.to_s,
          error: error.to_s
        }
      end

      def return_value(value)
        expression = value.is_a?(Symbol) ? "$#{value}" : value.to_s
        _acts << { type: :return_event, expression: expression }
      end

      def end_flow
        _acts << { type: :return_event, expression: "" }
      end

      def error_event
        _acts << { type: :error_event }
      end

      def continue_loop
        _acts << { type: :continue_event }
      end

      def rescue_all(&block)
        rescue_builder = RescueBuilder.new
        rescue_builder.instance_eval(&block) if block
        _acts << {
          type: :rescue_all,
          activities: rescue_builder.activities
        }
      end

      def decision(condition, &block)
        db = DecisionBuilder.new(condition.is_a?(Hash) ? condition : condition.to_s)
        db.instance_eval(&block) if block
        _acts << db.to_h
      end

      def type_decision(variable, &block)
        builder = TypeDecisionBuilder.new(variable.to_s)
        builder.instance_eval(&block) if block
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

    class FlowBuilder
      include FlowBodyDsl

      def initialize(name, runtime:, kind:, public:)
        @name                 = name.to_s
        @runtime              = runtime
        @kind                 = kind
        @public               = public
        @parameters           = []
        @return_type          = nil
        @doc                  = ""
        @calls                = []
        @repositories         = []
        @allowed_roles        = nil
        @body                 = nil
        @return_variable_name = nil
        @return_expression    = nil
        @expected_body_fingerprint = nil
        @allow_concurrent_execution = nil
        @mark_as_used = nil
        @excluded = nil
      end

      def parameter(name, type:)
        @parameters << { name: name.to_s, type: type.to_s }
      end

      def return_type(t) = (@return_type = t.to_s)
      def documentation(d) = (@doc = d)
      def allow_concurrent_execution(value = true) = (@allow_concurrent_execution = !!value)
      def mark_as_used(value = true) = (@mark_as_used = !!value)
      def excluded(value = true) = (@excluded = !!value)

      def allowed_roles(*roles)
        @allowed_roles = roles.map(&:to_s)
      end

      def call(microflow: nil, nanoflow: nil)
        choices = { microflow: microflow, nanoflow: nanoflow }.compact
        raise ArgumentError, "call requires exactly one target" unless choices.size == 1
        @calls << { kind: choices.keys.first, name: choices.values.first.to_s }
      end

      def uses_repository(name)
        @repositories << name.to_s
      end

      def rescue_all(&block)
        rb = RescueBuilder.new
        rb.instance_eval(&block) if block
        _acts << { type: :rescue_all, activities: rb.activities }
      end

      def return_value(var)
        if var.is_a?(Symbol)
          @return_variable_name = var.to_s
          @return_expression = "$#{var}"
        else
          @return_expression = var.to_s
        end
      end

      def body_fingerprint(value)
        @expected_body_fingerprint = value.to_s
      end

      def self.body_digest(body, return_expression)
        payload = canonical_body_value([body, return_expression])
        Digest::SHA256.hexdigest(JSON.generate(payload))
      end

      def self.canonical_body_value(value)
        case value
        when Hash
          value.keys.sort_by(&:to_s).to_h do |key|
            [key.to_s, canonical_body_value(value[key])]
          end
        when Array
          value.map { canonical_body_value(_1) }
        when Symbol
          { "__symbol__" => value.to_s }
        else
          value
        end
      end

      def to_h
        current_fingerprint = self.class.body_digest(@body, @return_expression)
        {
          name: @name, runtime: @runtime, kind: @kind, public: @public,
          parameters: @parameters, return_type: @return_type, documentation: @doc,
          calls: @calls, repositories: @repositories, allowed_roles: @allowed_roles,
          body: @body, return_variable_name: @return_variable_name,
          return_expression: @return_expression,
          allow_concurrent_execution: @allow_concurrent_execution,
          mark_as_used: @mark_as_used, excluded: @excluded,
          preserve_native_body: !@expected_body_fingerprint.nil? &&
            @expected_body_fingerprint == current_fingerprint
        }
      end

      private

      def _acts = (@body ||= [])
    end

    class DecisionBuilder
      def initialize(condition)
        @condition      = condition
        @true_branch    = []
        @false_branch   = []
        @branches       = {}
      end

      def on(value, &block)
        bb = BranchBuilder.new
        bb.instance_eval(&block) if block
        case value
        when true  then @true_branch  = bb.activities
        when false then @false_branch = bb.activities
        end
        @branches[value] = bb.activities
      end

      def to_h
        { type: :decision, condition: @condition,
          true_branch: @true_branch, false_branch: @false_branch,
          branches: @branches }
      end
    end

    class BranchBuilder
      include FlowBodyDsl
      attr_reader :activities

      def initialize
        @activities = []
      end

      private

      def _acts = @activities
    end

    class TypeDecisionBuilder
      def initialize(variable)
        @variable = variable
        @branches = {}
      end

      def on_type(type, &block)
        add_branch(type.to_s, &block)
      end

      def otherwise(&block)
        add_branch("", &block)
      end

      def to_h
        { type: :inheritance_decision, variable: @variable, branches: @branches }
      end

      private

      def add_branch(value, &block)
        branch = BranchBuilder.new
        branch.instance_eval(&block) if block
        @branches[value] = branch.activities
      end
    end

    class LoopBuilder
      include FlowBodyDsl

      def initialize(variable, as:)
        @variable   = variable
        @iterator   = as
        @activities = []
      end

      def to_h
        { type: :loop_over, variable: @variable, iterator: @iterator, activities: @activities }
      end

      private

      def _acts = @activities
    end

    class RescueBuilder
      include FlowBodyDsl
      attr_reader :activities

      def initialize
        @activities = []
      end

      private

      def _acts = @activities
    end

    class SetBuilder
      attr_reader :members

      def initialize
        @members = []
      end

      def set(attribute, to:)
        @members << { attribute: attribute.to_s, value: to }
      end

      def set_association(association, to:, operation: :set)
        @members << {
          association: association.to_s, value: to,
          operation: operation.to_s
        }
      end
    end

    MicroflowBuilder = FlowBuilder
  end
end
