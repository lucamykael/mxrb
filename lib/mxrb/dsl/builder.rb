# frozen_string_literal: true

require "digest"
require "json"
require "base64"
require_relative "integration_documents"

module Mxrb
  module Dsl
    # Validates project-security references that cross DSL builders.
    class SecurityValidator
      def initialize(modules, security)
        @modules = modules
        @security = security
      end

      def validate!
        return unless @security

        errors = demo_users.flat_map { reference_errors(_1) }
        duplicates = demo_users.group_by { _1.fetch(:name) }.select { |_name, users| users.size > 1 }
        errors << "duplicate demo user name(s): #{duplicates.keys.join(', ')}" unless duplicates.empty?
        return if errors.empty?

        raise ValidationError, "security validation failed:\n- #{errors.join("\n- ")}"
      end

      private

      def demo_users = Array(@security[:demo_users])

      def reference_errors(user)
        errors = []
        missing_roles = user.fetch(:roles) - user_roles
        errors << "demo user #{user[:name]} references missing user role(s): #{missing_roles.join(', ')}" unless
          missing_roles.empty?
        entity = user.fetch(:entity)
        errors << "demo user #{user[:name]} references missing user entity #{entity}" unless
          entity == "System.User" || entities.include?(entity)
        errors
      end

      def user_roles = @security.fetch(:user_roles, []).map { _1.fetch(:name) }

      def entities
        @modules.flat_map do |mod|
          definition = mod.to_h
          definition.fetch(:entities, []).map { "#{definition.fetch(:name)}.#{_1.fetch(:name)}" }
        end
      end
    end

    # Shared widget-building methods for PageBuilder and ContainerBuilder.
    # Includers must implement private `_widget_list` returning the target array.
    module WidgetDsl
      def text_box(name, attribute: nil, caption: nil, &block)
        _add_widget(:text_box, name, attribute: attribute, caption: caption, &block)
      end

      def number_input(name, attribute: nil, caption: nil, &block)
        _add_widget(:number_input, name, attribute: attribute, caption: caption, &block)
      end

      def text_area(name, attribute: nil, caption: nil, lines: 5, &block)
        _add_widget(
          :text_area, name, attribute: attribute, caption: caption, lines: lines, &block
        )
      end

      def check_box(name, attribute: nil, caption: nil, &block)
        _add_widget(:check_box, name, attribute: attribute, caption: caption, &block)
      end

      def date_picker(name, attribute: nil, caption: nil, &block)
        _add_widget(:date_picker, name, attribute: attribute, caption: caption, &block)
      end

      def radio_button_group(name, attribute: nil, caption: nil, horizontal: false, &block)
        _add_widget(
          :radio_button_group, name, attribute:, caption:, horizontal: horizontal == true, &block
        )
      end

      def reference_selector(name, attribute: nil, caption: nil, display_attribute: nil, &block)
        _add_widget(
          :reference_selector, name, attribute: attribute, caption: caption,
                                     display_attribute: display_attribute, &block
        )
      end

      def text(name, caption: nil, &block)
        _add_widget(:text, name, caption: caption || name.to_s, &block)
      end

      def page_title(name, &block)
        _add_widget(:page_title, name, &block)
      end

      def static_image(name, image:, alternative_text: '', width: 0, height: 0,
                       width_unit: :pixels, height_unit: :pixels, responsive: true, &block)
        _add_widget(
          :static_image, name, image: image.to_s, alternative_text: alternative_text.to_s,
                               width: width.to_i, height: height.to_i,
                               width_unit: width_unit.to_sym, height_unit: height_unit.to_sym,
                               responsive: responsive == true, &block
        )
      end

      def data_grid(name, entity: nil, selection: nil, &block)
        _add_widget(:data_grid, name, entity: entity, selection: selection, &block)
      end

      # Gallery projections remain present beside an authoritative page
      # deep_structure in exported projects. Accept the concise projection at
      # every widget nesting level so arbitrary native pages can be evaluated
      # and reconstructed from their lossless payload.
      def gallery(name, entity: nil, &block)
        _add_widget(:gallery, name, entity: entity, &block)
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

      def pluggable_widget(name, widget_id:, widget_name: nil, properties: {}, class_name: nil)
        _widget_list << {
          type: :pluggable_widget, name: name.to_s,
          options: {
            widget_id: widget_id.to_s, widget_name: (widget_name || name).to_s,
            properties: properties, class: class_name
          }.compact,
          events: []
        }
      end

      def native_widget(name, type:, deep_structure:)
        raise ArgumentError, "deep_structure requires a Hash" unless deep_structure.is_a?(Hash)

        _widget_list << {
          type: :native_widget, name: name.to_s,
          options: { native_type: type.to_s, deep_structure: deep_structure }, events: []
        }
      end

      # Exported native widget payloads can contain BSON identifiers at any
      # nesting level. Keep the reconstruction helper on the shared widget DSL
      # so pages, containers, and tab pages all evaluate the same export.
      def bson_binary(base64, subtype: :generic)
        BSON::Binary.new(Base64.strict_decode64(base64), subtype.to_sym)
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
      include WidgetDsl

      def initialize(type, name, **options)
        @type        = type
        @name        = name.to_s
        @options     = options
        @events      = []
        @columns     = []
        @tabs        = []
        @search_bar  = nil
        @toolbar     = nil
        @children    = []
        @filters     = []
      end

      def column(name, attribute: nil, caption: nil, filter: nil)
        @columns << {
          name: name.to_s, attribute: attribute&.to_s, caption:, filter:
        }.compact
      end

      def filter(widget) = @filters << widget

      def tab_page(name, caption: nil, &block)
        tab = TabPageBuilder.new(name, caption: caption)
        tab.instance_eval(&block) if block
        @tabs << tab.to_h
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
        define_method(event) do |microflow: nil, nanoflow: nil, page: nil, action: nil|
          choices = { microflow: microflow, nanoflow: nanoflow, page: page, action: action }.compact
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
        options[:filters]    = @filters    unless @filters.empty?
        value = { type: @type, name: @name, options: options, events: @events }
        value[:children] = @children unless @children.empty?
        value
      end

      private

      def _widget_list = @children
    end

    class TabPageBuilder
      include WidgetDsl

      def initialize(name, caption: nil)
        @name = name.to_s
        @caption = caption || name.to_s
        @widgets = []
      end

      def to_h = { name: @name, caption: @caption, widgets: @widgets }

      private

      def _widget_list = @widgets
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
    module ConnectorDeclarations
      def connector(protocol, version: nil, marketplace_id: nil)
        connector_requests << Protocols.request(protocol, version:, marketplace_id:)
      end

      def connector_plans(adapter: nil)
        connector_requests.map do |request|
          Protocols.plan(
            request.protocol, mendix_version: @mendix_version, version: request.version,
                              marketplace_id: request.marketplace_id, adapter:
          )
        end
      end

      def validate_connector_requests!
        return if connector_requests.empty?

        raise MarketplaceError,
              'connector declarations are preview-only; resolve and apply connector_plans ' \
              'to an existing MPR with the official Marketplace adapter'
      end

      def connector_requests = (@connector_requests ||= [])
    end

    class Builder
      include ConnectorDeclarations

      attr_reader :path

      def initialize(path)
        @path              = path
        @mendix_version    = "10.18.0"
        @modules           = []
        @security          = nil
        @navigation        = nil
        @design_system     = nil
        @native_units_path = nil
        @native_unit_overrides = []
        @project_assets = nil
        @ruby_app_sources_path = nil
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

      def navigation(&block)
        builder = NavigationBuilder.new
        builder.instance_eval(&block) if block
        @navigation = builder.to_h
      end

      def design_system(&block)
        builder = DesignSystemBuilder.new
        builder.instance_eval(&block) if block
        @design_system = builder.to_h
      end

      def native_units(path)
        @native_units_path = path
      end

      def project_assets(manifest, root:)
        @project_assets = {
          manifest: File.expand_path(manifest),
          root: File.expand_path(root)
        }
      end

      def ruby_app_sources(path)
        @ruby_app_sources_path = File.expand_path(path)
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

      def evaluate_dir(dir)
        return unless File.directory?(dir)

        Dir[File.join(dir, '*.rb')].sort.each { |path| evaluate(path) }
      end

      def build!
        validate_connector_requests!
        validate!
        Writer.new(@path, definition).write!
        self
      end

      def graph
        Architecture::Graph.new(definition)
      end

      def validate!
        validate_security!
        Architecture::Validator.new(graph).validate!
      end

      def validate_security!
        SecurityValidator.new(@modules, @security).validate!
      end

      def definition
        {
          version: @mendix_version,
          modules: @modules.map(&:to_h),
          security: @security,
          navigation: @navigation,
          design_system: @design_system,
          connectors: connector_requests.map(&:to_h),
          project_assets: @project_assets,
          ruby_app_sources_path: @ruby_app_sources_path,
          native_units_path: @native_units_path,
          native_unit_overrides: @native_unit_overrides
        }
      end
    end

    class SecurityBuilder
      def initialize
        @user_roles = []
        @demo_users = []
        @demo_users_declared = false
        @security_level = nil
        @admin_user_role = nil
        @demo_users_enabled = nil
        @guest_access_enabled = nil
        @guest_user_role = nil
        @sign_in_microflow = nil
        @password_policy = nil
        @password_policy_id = nil
        @id = nil
      end

      def mendix_id(value) = (@id = value.to_s)

      # Mendix stores the project security mode as an enum-like string such as
      # "CheckNothing" or "CheckEverything". Keep the native value explicit so
      # export/import does not silently weaken project security.
      def security_level(value)
        @security_level = value.to_s
      end

      def user_role(name, module_roles: [], admin: false, id: nil, guid: nil,
                    description: '', check_security: true, manageable_roles: [],
                    manage_users_without_roles: false)
        @user_roles << {
          name: name.to_s,
          module_roles: Array(module_roles).map(&:to_s),
          admin: admin, id: id.to_s, guid: guid.to_s,
          description: description.to_s, check_security: check_security == true,
          manageable_roles: Array(manageable_roles).map(&:to_s),
          manage_users_without_roles: manage_users_without_roles == true
        }
      end

      def admin_user_role(name)
        @admin_user_role = name.to_s
      end

      def demo_users(enabled = true)
        @demo_users_enabled = enabled == true
      end

      def demo_user(name, entity:, roles:, password:, id: nil)
        user_name = name.to_s
        entity_name = entity.to_s
        role_names = Array(roles).map(&:to_s).uniq
        secret = password.to_s
        raise ArgumentError, 'demo user name must not be empty' if user_name.empty?
        raise ArgumentError, 'demo user name must not contain whitespace' unless user_name.match?(/\A[^\s]+\z/)
        unless entity_name.match?(/\A[A-Za-z][A-Za-z0-9_]*\.[A-Za-z][A-Za-z0-9_]*\z/)
          raise ArgumentError, 'demo user entity must be qualified as Module.Entity'
        end
        raise ArgumentError, 'demo user requires at least one role' if role_names.empty?
        raise ArgumentError, 'demo user password must not be empty' if secret.empty?

        @demo_users << {
          name: user_name, id: id.to_s, entity: entity_name, roles: role_names, password: secret
        }
        @demo_users_declared = true
        @demo_users_enabled = true
      end

      def evaluate(path)
        instance_eval(File.read(path), path, 1)
      end

      def evaluate_dir(dir)
        return unless File.directory?(dir)

        Dir[File.join(dir, '*.rb')].sort.each { |path| evaluate(path) }
      end

      def guest_access(enabled = true, role: nil)
        @guest_access_enabled = enabled == true
        @guest_user_role = role&.to_s
      end

      def sign_in_microflow(name)
        @sign_in_microflow = name&.to_s
      end

      def password_policy(id: nil, **options)
        @password_policy_id = id.to_s
        @password_policy = options.transform_keys(&:to_sym)
      end

      def to_h
        {
          user_roles: @user_roles,
          demo_users: @demo_users_declared ? @demo_users : nil,
          security_level: @security_level,
          admin_user_role: @admin_user_role,
          demo_users_enabled: @demo_users_enabled,
          guest_access_enabled: @guest_access_enabled,
          guest_user_role: @guest_user_role,
          sign_in_microflow: @sign_in_microflow,
          password_policy: @password_policy,
          password_policy_id: @password_policy_id,
          id: @id
        }
      end
    end

    class NavigationBuilder
      def initialize
        @profiles = []
      end

      def profile(name, home_page: nil, home_microflow: nil, sign_in_page: nil,
                  menu: nil, role_homes: {}, offline: false, kind: nil,
                  app_title: nil, app_icon: nil, &block)
        profile = NavigationProfileBuilder.new(
          name, home_page:, home_microflow:, sign_in_page:, menu:, role_homes:,
                offline:, kind:, app_title:, app_icon:
        )
        profile.instance_eval(&block) if block
        @profiles << profile.to_h
      end

      def to_h
        { profiles: @profiles }
      end
    end

    class NavigationProfileBuilder
      def initialize(name, **options)
        @name = name.to_s
        @home_page = optional_string(options, :home_page)
        @home_microflow = optional_string(options, :home_microflow)
        @sign_in_page = optional_string(options, :sign_in_page)
        @menu = optional_string(options, :menu)
        @offline = options[:offline] == true
        @kind = optional_string(options, :kind)
        @app_icon = optional_string(options, :app_icon)
        @app_title = normalize_translations(options[:app_title])
        @role_homes = options.fetch(:role_homes, {}).to_h.transform_keys(&:to_s)
                             .transform_values(&:to_s)
        @role_home_details = []
        @items = []
      end

      def title(locale, text)
        @app_title[locale.to_s] = text.to_s
      end

      def home_for(role, page: nil, microflow: nil)
        @role_home_details << {
          role: role.to_s, page: page&.to_s, microflow: microflow&.to_s
        }.compact
      end

      def item(caption, page: nil, microflow: nil, icon: nil, translations: {}, &block)
        builder = NavigationMenuItemBuilder.new(
          caption, page:, microflow:, icon:, translations:
        )
        builder.instance_eval(&block) if block
        @items << builder.to_h
      end

      def evaluate(path)
        instance_eval(File.read(path), path, 1)
      end

      def evaluate_dir(dir)
        return unless File.directory?(dir)

        Dir[File.join(dir, '*.rb')].sort.each { |path| evaluate(path) }
      end

      def to_h
        {
          name: @name, home_page: @home_page, home_microflow: @home_microflow,
          sign_in_page: @sign_in_page, menu: @menu, role_homes: @role_homes,
          role_home_details: @role_home_details, offline: @offline, kind: @kind,
          app_title: @app_title, app_icon: @app_icon, items: @items
        }
      end

      private

      def optional_string(options, key)
        options[key]&.to_s
      end

      def normalize_translations(value)
        return {} if value.nil?
        return value.to_h.transform_keys(&:to_s).transform_values(&:to_s) if value.respond_to?(:to_h)

        { "en_US" => value.to_s }
      end
    end

    class NavigationMenuItemBuilder
      def initialize(caption, page: nil, microflow: nil, icon: nil, translations: {})
        @caption = normalize_caption(caption)
        @caption.merge!(translations.to_h.transform_keys(&:to_s).transform_values(&:to_s))
        @page = page&.to_s
        @microflow = microflow&.to_s
        @icon = icon
        @items = []
      end

      def item(caption, page: nil, microflow: nil, icon: nil, translations: {}, &block)
        child = self.class.new(caption, page:, microflow:, icon:, translations:)
        child.instance_eval(&block) if block
        @items << child.to_h
      end

      def to_h
        {
          caption: @caption, page: @page, microflow: @microflow,
          icon: @icon, items: @items
        }
      end

      private

      def normalize_caption(caption)
        return { "en_US" => caption.to_s } unless caption.respond_to?(:to_h)

        caption.to_h.transform_keys(&:to_s).transform_values(&:to_s)
      end
    end

    class DesignSystemBuilder
      TOKEN_KINDS = %i[color spacing radius typography breakpoint].freeze

      def initialize
        @tokens = []
        @themes = []
        @layouts = []
        @components = []
        @accessibility = []
        @contrast_pairs = []
        @forbid_literal_colors = false
      end

      TOKEN_KINDS.each do |kind|
        define_method(kind) do |name, value: nil|
          @tokens << { kind:, name: name.to_s, value: value&.to_s }
        end
      end

      def layout(name)
        @layouts << name.to_s
      end

      def component(name)
        @components << name.to_s
      end

      def accessibility(rule)
        @accessibility << rule.to_s
      end

      def theme(name, inherits: nil, &block)
        builder = DesignThemeBuilder.new(name, inherits:)
        builder.instance_eval(&block) if block
        @themes << builder.to_h
      end

      def contrast(foreground:, background:, level: :aa)
        @contrast_pairs << {
          foreground: foreground.to_s, background: background.to_s, level: level.to_s
        }
      end

      def forbid_literal_colors(value = true)
        @forbid_literal_colors = value == true
      end

      def to_h
        {
          tokens: @tokens, layouts: @layouts,
          components: @components, accessibility: @accessibility,
          themes: @themes, contrast_pairs: @contrast_pairs,
          forbid_literal_colors: @forbid_literal_colors
        }
      end
    end

    class DesignThemeBuilder
      def initialize(name, inherits: nil)
        @name = name.to_s
        @inherits = inherits&.to_s
        @tokens = []
      end

      DesignSystemBuilder::TOKEN_KINDS.each do |kind|
        define_method(kind) do |name, value: nil|
          @tokens << { kind:, name: name.to_s, value: value&.to_s }
        end
      end

      def to_h = { name: @name, inherits: @inherits, tokens: @tokens }
    end

    class EnumerationBuilder
      attr_reader :name

      def initialize(name, **options)
        @name = name.to_s
        @values = []
        @id = options[:id]&.to_s
        @unit_id = options[:unit_id]&.to_s
        @doc = options.fetch(:documentation, '').to_s
        @excluded = options.fetch(:excluded, false) == true
        @export_level = options.fetch(:export_level, 'Hidden').to_s
        @remote_source = options[:remote_source]
        @values_marker = options.fetch(:values_marker, 3).to_i
      end

      def value(name, caption: nil, captions: nil, id: nil, caption_id: nil,
                caption_ids: {}, image: '', remote_value: nil,
                translations_marker: 3, export_level: nil)
        localized = normalized_captions(name, caption, captions)
        @values << {
          name: name.to_s, id: id&.to_s, caption_id: caption_id&.to_s,
          captions: localized.transform_keys(&:to_s).transform_values(&:to_s),
          caption_ids: caption_ids.to_h.transform_keys(&:to_s).transform_values(&:to_s),
          image: image.to_s, remote_value:, translations_marker: translations_marker.to_i,
          export_level: export_level&.to_s
        }
      end

      def documentation(d) = (@doc = d)

      def to_h
        {
          name: @name, id: @id, unit_id: @unit_id, values: @values,
          documentation: @doc, excluded: @excluded, export_level: @export_level,
          remote_source: @remote_source, values_marker: @values_marker
        }
      end

      private

      def normalized_captions(name, caption, captions)
        return captions.to_h unless captions.nil?

        { 'en_US' => caption.nil? ? name.to_s : caption }
      end
    end

    class ConstantBuilder
      CONSTANT_TYPES = {
        string: "DataTypes$StringType", integer: "DataTypes$IntegerType",
        boolean: "DataTypes$BooleanType", decimal: "DataTypes$DecimalType",
        datetime: "DataTypes$DateTimeType"
      }.freeze

      attr_reader :name

      def initialize(name, type:, value: nil, **options)
        @name = name.to_s
        @type = type.to_sym
        @value = value
        @id = options[:id]&.to_s
        @type_id = options[:type_id]&.to_s
        @unit_id = options[:unit_id]&.to_s
        @doc = options.fetch(:documentation, '').to_s
        @excluded = options.fetch(:excluded, false) == true
        @export_level = options.fetch(:export_level, 'Hidden').to_s
        @exposed_to_client = options.fetch(:exposed_to_client, false) == true
      end

      def documentation(d) = (@doc = d)

      def to_h
        {
          name: @name, type: @type, value: @value, documentation: @doc,
          id: @id, type_id: @type_id, unit_id: @unit_id, excluded: @excluded,
          export_level: @export_level, exposed_to_client: @exposed_to_client
        }
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

    class ModuleBuilder # rubocop:disable Metrics/ClassLength
      include IntegrationDocuments

      attr_reader :name, :entities, :pages, :microflows, :nanoflows, :repositories,
                  :associations, :menus, :module_roles, :enumerations, :constants,
                  :scheduled_events, :native_documents, :managed_native_document_types

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
        @native_documents = []
        @managed_native_document_types = []
      end

      def entity(name, &block)
        eb = EntityBuilder.new(name)
        eb.instance_eval(&block) if block
        @entities << eb.to_h
      end

      def page(name, &block)
        default_layout = "#{@name}.ApplicationLayout"
        pb = PageBuilder.new(name, default_layout:)
        pb.instance_eval(&block) if block
        page = pb.to_h
        ensure_application_layout if page.fetch(:layout) == default_layout
        @pages << page
      end

      def menu(name, &block)
        mb = MenuBuilder.new(name)
        mb.instance_eval(&block) if block
        @menus << mb.to_h
      end

      def module_role(name, id: nil, description: "")
        @module_roles << { name: name.to_s, id: id.to_s, description: description.to_s }
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

      def repository(name, implementation: nil, public: false, documentation: "")
        @repositories << {
          name: name.to_s, implementation: implementation&.to_s,
          public: public, documentation: documentation.to_s
        }
      end

      def enumeration(name, **options, &block)
        eb = EnumerationBuilder.new(name, **options)
        eb.instance_eval(&block) if block
        @enumerations << eb.to_h
      end

      def constant(name, type:, value: nil, **options, &block)
        cb = ConstantBuilder.new(name, type:, value:, **options)
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

      def native_document(name, type:, deep_structure:, containment: 'Documents',
                          unit_id: nil, container_id: nil)
        raise ArgumentError, 'deep_structure requires a Hash' unless deep_structure.is_a?(Hash)

        @native_documents << {
          name: name.to_s, type: type.to_s, containment: containment.to_s,
          unit_id: unit_id&.to_s, container_id: container_id&.to_s,
          doc: { '$Type' => type.to_s, 'Name' => name.to_s }.merge(deep_structure)
        }
      end

      # Marks routed native documents as authoritative for this module. The
      # compiler may then remove a document when its Ruby declaration is
      # removed, while unrelated and unknown document types remain untouched.
      def manage_native_documents(*types)
        @managed_native_document_types |= types.flatten.map(&:to_s)
      end

      def bson_binary(base64, subtype: :generic)
        BSON::Binary.new(Base64.strict_decode64(base64), subtype.to_sym)
      end

      # Native responsive application shell. It deliberately uses only Mendix
      # core widgets, so generated projects do not depend on Atlas Core merely
      # to display their navigation.
      def layout(name = :ApplicationLayout, title: nil, navigation: :Responsive)
        appearance = lambda do |class_name = ''|
          {
            '$ID' => SecureRandom.uuid, '$Type' => 'Forms$Appearance',
            'Class' => class_name, 'DesignProperties' => IO::BsonCodec.build_array([]),
            'DynamicClasses' => '', 'Style' => ''
          }
        end
        placeholder = {
          '$ID' => SecureRandom.uuid, '$Type' => 'Forms$Placeholder',
          'Appearance' => appearance.call, 'Name' => 'Main', 'TabIndex' => 0
        }
        text = lambda do |value|
          {
            '$ID' => SecureRandom.uuid, '$Type' => 'Texts$Text',
            'Items' => IO::BsonCodec.build_array([
                                                   {
                                                     '$ID' => SecureRandom.uuid, '$Type' => 'Texts$Translation',
                                                     'LanguageCode' => 'en_US', 'Text' => value.to_s
                                                   }
                                                 ])
          }
        end
        client_template = lambda do |value|
          {
            '$ID' => SecureRandom.uuid, '$Type' => 'Forms$ClientTemplate',
            'Fallback' => text.call(''),
            'Parameters' => IO::BsonCodec.build_array([], marker: 2),
            'Template' => text.call(value)
          }
        end
        no_action = {
          '$ID' => SecureRandom.uuid, '$Type' => 'Forms$NoAction',
          'DisabledDuringExecution' => true
        }
        navigation_tree = if navigation
                            {
                              '$ID' => SecureRandom.uuid, '$Type' => 'Forms$NavigationTree',
                              'Appearance' => appearance.call('mxrb-navigation'),
                              'MenuSource' => {
                                '$ID' => SecureRandom.uuid, '$Type' => 'Forms$NavigationSource',
                                'NavigationProfile' => navigation.to_s
                              },
                              'Name' => 'navigationTree1', 'TabIndex' => 0
                            }
                          end
        left = if navigation_tree
                 {
                   '$ID' => SecureRandom.uuid, '$Type' => 'Forms$ScrollContainerRegion',
                   'Appearance' => appearance.call('region-sidebar'),
                   'Size' => 264, 'SizeMode' => 'Pixels',
                   'ToggleMode' => 'ShrinkContentInitiallyClosed',
                   'Widgets' => IO::BsonCodec.build_array([navigation_tree], marker: 2)
                 }
               end
        sidebar_toggle = if navigation_tree
                           {
                             '$ID' => SecureRandom.uuid, '$Type' => 'Forms$SidebarToggleButton',
                             'Appearance' => appearance.call('mxrb-sidebar-toggle'),
                             'ButtonStyle' => 'Primary', 'CaptionTemplate' => client_template.call('Menu'),
                             'ConditionalVisibilitySettings' => nil, 'Icon' => nil,
                             'Name' => 'sidebarToggle1', 'RenderType' => 'Button', 'TabIndex' => 0,
                             'Tooltip' => text.call('Toggle navigation')
                           }
                         end
        brand = {
          '$ID' => SecureRandom.uuid, '$Type' => 'Forms$DynamicText',
          'Appearance' => appearance.call('mxrb-brand'), 'Class' => '',
          'ConditionalVisibilitySettings' => nil,
          'Content' => client_template.call(title || name.to_s),
          'Name' => 'applicationTitle', 'NativeAccessibilitySettings' => nil,
          'NativeTextStyle' => 'Text', 'RenderMode' => 'Text', 'Style' => '',
          'TabIndex' => 0
        }
        topbar_content = {
          '$ID' => SecureRandom.uuid, '$Type' => 'Forms$DivContainer',
          'Appearance' => appearance.call('mxrb-topbar'),
          'ConditionalVisibilitySettings' => nil, 'Name' => 'topbarContent',
          'OnClickAction' => no_action, 'RenderMode' => 'Div',
          'ScreenReaderHidden' => false, 'TabIndex' => 0,
          'Widgets' => IO::BsonCodec.build_array([sidebar_toggle, brand].compact, marker: 2)
        }
        top = {
          '$ID' => SecureRandom.uuid, '$Type' => 'Forms$ScrollContainerRegion',
          'Appearance' => appearance.call('region-topbar'),
          'Size' => 72, 'SizeMode' => 'Pixels', 'ToggleMode' => 'None',
          'Widgets' => IO::BsonCodec.build_array([topbar_content], marker: 2)
        }
        center = {
          '$ID' => SecureRandom.uuid, '$Type' => 'Forms$ScrollContainerRegion',
          'Appearance' => appearance.call('region-content'),
          'Size' => 200, 'SizeMode' => 'Auto',
          'ToggleMode' => 'None',
          'Widgets' => IO::BsonCodec.build_array([placeholder], marker: 2)
        }
        container = {
          '$ID' => SecureRandom.uuid, '$Type' => 'Forms$ScrollContainer',
          'Alignment' => 'Center', 'Bottom' => nil, 'CenterRegion' => center,
          'Appearance' => appearance.call, 'LayoutMode' => 'Headline', 'Left' => left,
          'Name' => 'scrollContainer1', 'Right' => nil, 'ScrollBehavior' => 'PerRegion',
          'NativeHideScrollbars' => false, 'TabIndex' => 0, 'Top' => top,
          'Width' => 960, 'WidthMode' => 'Auto'
        }
        content = {
          '$ID' => SecureRandom.uuid, '$Type' => 'Forms$WebLayoutContent',
          'LayoutCall' => nil, 'LayoutType' => 'Responsive',
          'Widgets' => IO::BsonCodec.build_array([container], marker: 2)
        }
        native_document(
          name, type: 'Forms$Layout', deep_structure: {
            'Appearance' => appearance.call('mxrb-application-shell'), 'CanvasHeight' => 600,
            'CanvasWidth' => 800, 'Content' => content, 'Documentation' => '',
            'Excluded' => false, 'ExportLevel' => 'Hidden'
          }
        )
      end

      def ensure_application_layout
        return if @native_documents.any? do |document|
          document[:type] == 'Forms$Layout' && document[:name] == 'ApplicationLayout'
        end

        layout(:ApplicationLayout, title: @name, navigation: nil)
      end

      def evaluate(path)
        instance_eval(File.read(path), path, 1)
      end

      def evaluate_dir(dir)
        return unless File.directory?(dir)

        Dir[File.join(dir, '*.rb')].sort.each { |path| evaluate(path) }
      end

      def to_h
        {
          name: @name, entities: @entities, pages: @pages,
          microflows: @microflows, nanoflows: @nanoflows,
          repositories: @repositories, menus: @menus, module_roles: @module_roles,
          enumerations: @enumerations, constants: @constants,
          scheduled_events: @scheduled_events, native_documents: @native_documents,
          managed_native_document_types: @managed_native_document_types
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

    class EntityBuilder # rubocop:disable Metrics/ClassLength
      ATTR_TYPES = %i[string integer long float decimal boolean datetime autonumber hashstring binary enum].freeze
      ASSOCIATION_TYPES = %i[Reference ReferenceSet].freeze
      ASSOCIATION_OWNERS = %i[Default Both].freeze
      ASSOCIATION_STORAGE_FORMATS = %i[Column Table].freeze
      CARDINALITIES = {
        many_to_one: %i[Reference Default],
        one_to_one: %i[Reference Both],
        many_to_many: %i[ReferenceSet Default]
      }.freeze

      attr_reader :name

      def initialize(name)
        @name         = name.to_s
        @attributes   = []
        @persistable  = true
        @doc          = ""
        @associations = []
        @lifecycle    = nil
        @access_rules = nil
        @generalization = nil
        @system_members = nil
        @indexes = nil
        @oql_view = nil
      end

      ATTR_TYPES.each do |type|
        define_method(type) do |attr_name, **opts|
          @attributes << { name: attr_name.to_s, type: type, **opts }
        end
      end

      def non_persistent!  = (@persistable = false)
      def documentation(d) = (@doc = d)

      # Marks an entity as an OQL-backed view. Modern Mendix projects keep the
      # query in a separate ViewEntitySourceDocument; older projects may keep
      # it directly on the embedded entity.
      def oql_view(source: nil, query: nil)
        raise ArgumentError, 'oql_view requires source or query' if source.nil? && query.nil?

        @oql_view = { source: source&.to_s, query: query&.to_s }.compact
        @persistable = false
      end

      def generalizes(entity, id: nil)
        @generalization = { target: entity.to_s, id: id&.to_s }
      end

      def system_members(owner: false, created_date: false, changed_date: false, changed_by: false)
        @system_members = {
          owner: owner, created_date: created_date,
          changed_date: changed_date, changed_by: changed_by
        }
      end

      def index(*attributes, id: nil, guid: nil, include_offline: false, ascending: true,
                members: nil)
        names = attributes.flatten.map(&:to_s)
        raise ArgumentError, 'index requires at least one attribute' if names.empty? && !members

        @indexes ||= []
        declarations = normalize_index_declarations(names, ascending, members)
        @indexes << {
          id: id&.to_s, guid: guid&.to_s, members: declarations,
          attributes: declarations.map { _1.fetch(:name).to_s },
          ascending: declarations.map { _1.fetch(:ascending, true) == true },
          include_offline: include_offline == true
        }
      end

      def association(target, type: :Reference, owner: :Default, name: nil, cardinality: nil,
                      documentation: '', parent_delete: :NoAction, child_delete: :NoAction,
                      storage_format: nil)
        if cardinality
          type, owner = CARDINALITIES.fetch(cardinality.to_sym) do
            raise ArgumentError, 'cardinality must be :many_to_one, :one_to_one, or :many_to_many'
          end
        end
        type = type.to_sym
        owner = owner.to_sym
        unless ASSOCIATION_TYPES.include?(type)
          raise ArgumentError, "association type must be Reference or ReferenceSet"
        end
        raise ArgumentError, "association owner must be Default or Both" unless ASSOCIATION_OWNERS.include?(owner)
        storage_format = normalize_association_storage_format(storage_format)

        @associations << {
          name: (name || "#{@name}_#{target}").to_s,
          target: target.to_s,
          type: type,
          owner: owner,
          documentation: documentation.to_s,
          parent_delete: parent_delete.to_sym,
          child_delete: child_delete.to_sym,
          storage_format: storage_format
        }
      end

      %i[before_commit after_commit before_delete after_delete].each do |event|
        define_method(event) do |microflow:, id: nil, pass_event_object: true,
                                raise_error_on_false: nil|
          @lifecycle ||= []
          raise_error = if raise_error_on_false.nil?
                          event.to_s.start_with?('before_')
                        else
                          raise_error_on_false == true
                        end
          @lifecycle << {
            id: id&.to_s, event:, handler: microflow.to_s,
            pass_event_object: pass_event_object == true,
            raise_error_on_false: raise_error
          }
        end
      end

      # access_rule "Module.Role", create: true, delete: false, read: :all, write: [:Name]
      def access_rule(*roles, id: nil, documentation: '', create: false, delete: false,
                      read: :none, write: :none, xpath: "", xpath_caption: nil,
                      default_rights: nil, members: nil)
        @access_rules ||= []
        @access_rules << {
          id: id&.to_s,
          documentation: documentation.to_s,
          roles: roles.map(&:to_s),
          create: create,
          delete: delete,
          read: normalize_access(read),
          write: normalize_access(write),
          xpath: xpath.to_s,
          xpath_caption: xpath_caption&.to_s,
          default_rights: default_rights&.to_s,
          members: members&.map { _1.transform_keys(&:to_sym) }
        }
      end

      def to_h
        {
          name: @name, persistable: @persistable, documentation: @doc,
          attributes: @attributes, associations: @associations, lifecycle: @lifecycle,
          access_rules: @access_rules, generalization: @generalization,
          system_members: @system_members, indexes: @indexes, oql_view: @oql_view
        }
      end

      private

      def normalize_index_declarations(names, ascending, members)
        return members.map { _1.transform_keys(&:to_sym) } if members

        directions = Array(ascending)
        if directions.size != 1 && directions.size != names.size
          raise ArgumentError, 'ascending must be one boolean or one value per indexed attribute'
        end

        directions *= names.size if directions.size == 1
        names.zip(directions).map do |name, direction|
          { name:, ascending: direction == true, type: :Normal }
        end
      end

      def normalize_association_storage_format(value)
        return if value.nil?

        format = value.to_sym
        return format if ASSOCIATION_STORAGE_FORMATS.include?(format)

        raise ArgumentError, "association storage format must be Column or Table"
      end

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

      def initialize(name, default_layout: 'Atlas_Default')
        @name          = name.to_s
        @layout        = default_layout.to_s
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
        define_method(event) do |target: nil, microflow: nil, nanoflow: nil, page: nil, action: nil|
          choices = { microflow: microflow, nanoflow: nanoflow, page: page, action: action }.compact
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

      def list_operation(operation, list, as:, with: nil, expression: nil)
        _acts << {
          type: :list_operation, operation: operation.to_s,
          variable: list.to_s, second: with&.to_s,
          expression: expression&.to_s, output: as.to_s
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
                    request_body: nil, request_parameters: [],
                    result_mapping: nil, as: nil, result_entity: nil,
                    timeout: nil, commit: :yes_without_events,
                    result_handling: :mapping,
                    result_content_type: :json, force_single: false, single: false,
                    object_handling: :create, parameter_variable: nil,
                    error_result: :http_response, error: :rollback)
        _acts << {
          type: :call_rest, method: method.to_s, location: location.to_s,
          location_parameters: Array(location_parameters),
          headers: headers.transform_keys(&:to_s),
          request_mapping: request_mapping.to_s,
          request_variable: request_variable.to_s,
          request_body: _optional_string(request_body),
          request_parameters: Array(request_parameters),
          result_mapping: result_mapping.to_s, variable: as.to_s,
          result_entity: result_entity.to_s, timeout: timeout.to_s,
          commit: commit.to_s, result_handling: result_handling.to_s,
          result_content_type: result_content_type.to_s,
          force_single: force_single == true, single: single == true,
          object_handling: object_handling.to_s,
          parameter_variable: parameter_variable.to_s,
          error_result: error_result.to_s,
          error: error.to_s
        }
      end

      def execute_database_query(query = nil, as: nil, dynamic_query: nil,
                                 parameters: {}, connection_parameters: {},
                                 error: :rollback)
        _acts << {
          type: :execute_database_query, query: query.to_s,
          dynamic_query: dynamic_query.to_s, variable: as&.to_s,
          parameters: parameters.map { |name, value| { name: name.to_s, value: value } },
          connection_parameters: connection_parameters.map do |name, value|
            { name: name.to_s, value: value }
          end,
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

      def _optional_string(value)
        value&.to_s
      end

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
        @apply_entity_access = nil
        @mark_as_used = nil
        @excluded = nil
      end

      def parameter(name, type:)
        @parameters << { name: name.to_s, type: type.is_a?(Hash) ? type : type.to_s }
      end

      def bson_binary(base64, subtype: :generic)
        BSON::Binary.new(Base64.strict_decode64(base64), subtype.to_sym)
      end

      def return_type(type) = (@return_type = type.is_a?(Hash) ? type : type.to_s)
      def documentation(d) = (@doc = d)
      def allow_concurrent_execution(value = true) = (@allow_concurrent_execution = !!value)
      def apply_entity_access(value = true) = (@apply_entity_access = !!value)
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
          apply_entity_access: @apply_entity_access,
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
