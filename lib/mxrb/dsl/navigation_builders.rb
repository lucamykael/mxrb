# frozen_string_literal: true

module Mxrb
  module Dsl
    class NavigationBuilder
      def initialize
        @profiles = []
      end

      def profile(name, home_page: nil, home_microflow: nil, sign_in_page: nil,
                  menu: nil, role_homes: {}, offline: false, kind: nil,
                  app_title: nil, app_icon: nil, enabled: nil, offline_enabled: nil,
                  throw_partial_sync_error: nil, sign_in_title: nil,
                  sign_in_location: nil, not_found_page: nil,
                  not_found_microflow: nil, home_nanoflow: nil, settings: {}, &block)
        profile = NavigationProfileBuilder.new(
          name, home_page:, home_microflow:, sign_in_page:, menu:, role_homes:,
                offline:, kind:, app_title:, app_icon:, enabled:, offline_enabled:,
                throw_partial_sync_error:, sign_in_title:, sign_in_location:,
                not_found_page:, not_found_microflow:, home_nanoflow:, settings:
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
        @enabled = optional_boolean(options, :enabled)
        @offline_enabled = optional_boolean(options, :offline_enabled)
        @throw_partial_sync_error = optional_boolean(options, :throw_partial_sync_error)
        @sign_in_title = normalize_translations(options[:sign_in_title])
        @sign_in_location = optional_string(options, :sign_in_location)
        @not_found_page = optional_string(options, :not_found_page)
        @not_found_microflow = optional_string(options, :not_found_microflow)
        @home_nanoflow = optional_string(options, :home_nanoflow)
        @settings = native_settings(options.fetch(:settings, {}))
        @bottom_bar = []
        @offline_entities = []
        @role_homes = options.fetch(:role_homes, {}).to_h.transform_keys(&:to_s)
                             .transform_values(&:to_s)
        @role_home_details = []
        @items = []
      end

      def title(locale, text)
        @app_title[locale.to_s] = text.to_s
      end

      def login_title(locale, text)
        @sign_in_title[locale.to_s] = text.to_s
      end

      def home_for(role, page: nil, microflow: nil, nanoflow: nil)
        @role_home_details << {
          role: role.to_s, page: page&.to_s, microflow: microflow&.to_s, nanoflow: nanoflow&.to_s
        }.compact
      end

      # An entity the profile synchronizes to the device: sync_mode :none,
      # :none_and_preserve_data or :all, with an optional XPath constraint.
      def offline_entity(entity, sync_mode: :none, constraint: nil, compatibility_mode: nil)
        entry = { entity: entity.to_s, sync_mode: Model::OfflineEntityConfigs.sync_mode(sync_mode) }
        entry[:constraint] = constraint.to_s unless constraint.to_s.empty?
        entry[:compatibility_mode] = true if compatibility_mode == true
        @offline_entities << entry
      end

      # A native profile's bottom bar entry; a page may appear only once.
      def bottom_bar_item(caption, page:, icon: nil, translations: {})
        @bottom_bar << {
          caption: { 'en_US' => caption.to_s }.merge(normalize_translations(translations)),
          page: page.to_s, icon:
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
          app_title: @app_title, app_icon: @app_icon, enabled: @enabled,
          offline_enabled: @offline_enabled,
          throw_partial_sync_error: @throw_partial_sync_error,
          sign_in_title: @sign_in_title, sign_in_location: @sign_in_location,
          not_found_page: @not_found_page, not_found_microflow: @not_found_microflow,
          items: @items, home_nanoflow: @home_nanoflow, settings: @settings, bottom_bar: @bottom_bar,
          offline_entities: @offline_entities
        }
      end

      private

      def native_settings(values)
        settings = values.to_h.transform_keys(&:to_sym)
        unknown = settings.keys - Model::NativeNavigationProfile::SETTINGS.keys
        raise ArgumentError, "unknown native navigation settings: #{unknown.join(', ')}" unless unknown.empty?

        settings
      end

      def optional_string(options, key)
        options[key]&.to_s
      end

      def optional_boolean(options, key)
        value = options[key]
        value == true unless value.nil?
      end

      def normalize_translations(value)
        return {} if value.nil?
        return value.to_h.transform_keys(&:to_s).transform_values(&:to_s) if value.respond_to?(:to_h)

        { 'en_US' => value.to_s }
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
        return { 'en_US' => caption.to_s } unless caption.respond_to?(:to_h)

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
  end
end
