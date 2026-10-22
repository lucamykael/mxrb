# frozen_string_literal: true

module Mxrb
  module Compiler
    # Compiles the navigation document as MxBuild writes it: each profile with
    # the fields of the version's Runtime schema, the widgets the web documents
    # use and, for a native profile, the offline configuration of every entity
    # the app synchronizes.
    class NavigationDocumentCompiler
      include RuntimeNodes

      NATIVE_PROFILE = 'Navigation$NativeNavigationProfile'
      WEB_PROFILE_KINDS = %w[Responsive ResponsiveOffline Tablet TabletOffline Phone PhoneOffline].freeze
      WEB_PROFILE = 'Navigation$NavigationProfile'
      # What MxBuild writes for the fields of a web profile the MPR leaves out.
      PROFILE_DEFAULTS = {
        'HomeItems' => [], 'AppIcon' => '', 'ThrowPartialSyncError' => true,
        'ProgressiveWebAppSettings' => nil, 'NotFoundHomepage' => nil
      }.freeze

      def initialize(schema, source: nil)
        @schema = schema
        @source = source
        @page_locations = page_locations(source)
        @widgets = WebWidgetInventory.new(source)
        @grids = NavigationGridCompiler.new(schema, source, @widgets)
        @synchronized = SynchronizedEntities.new(source)
      end

      def compile(unit)
        document = unit.document
        node(document, 'Profiles' => array(document['Profiles']).map { profile(_1) },
                       'Grids' => @grids.compile,
                       'PluginWidgets' => plugin_widgets,
                       'CustomWidgetModules' => @widgets.ids(plugin: false))
      end

      private

      # MxBuild 10 lists the pluggable widgets of native snippets after the web
      # ones; MxBuild 11 leaves them out.
      def plugin_widgets
        web = @widgets.ids(plugin: true)
        @source.respond_to?(:version) && major_version < 11 ? (web + @widgets.native_ids).uniq : web
      end

      # What MxBuild writes for a field of a profile the MPR leaves out.
      def derive(source, field)
        return PROFILE_DEFAULTS[field] if source['$Type'] == WEB_PROFILE && PROFILE_DEFAULTS.key?(field)

        case [source['$Type'], field]
        when [WEB_PROFILE, 'AppTitle'] then { '$ID' => derived_id(source, 'app-title'), '$Type' => 'Texts$Text' }
        when [WEB_PROFILE, 'LoginPageSettings'] then login_page_settings(source)
        else super
        end
      end

      def login_page_settings(profile)
        node('$ID' => derived_id(profile, 'login-page'), '$Type' => 'Forms$FormSettings', 'TitleOverride' => nil,
             'ParameterMappings' => [], 'Form' => '')
      end

      # A native profile is offline; a web one only when its kind says so
      # (ResponsiveOffline, TabletOffline, PhoneOffline). MxBuild reads a kind
      # it does not know, such as the bare 'Offline' older projects wrote, as
      # the Responsive default.
      def profile(source)
        native = source['$Type'] == NATIVE_PROFILE
        kind = WEB_PROFILE_KINDS.include?(source['Kind']) ? source['Kind'] : 'Responsive'
        offline = native || kind.end_with?('Offline')
        values = { 'OfflineEntityConfigsRuntime' => offline ? offline_configs(source) : [], 'IsOffline' => offline }
        values['Kind'] = kind unless native
        node(source, **values)
      end

      # Mendix 11 synchronizes every persistable entity, online unless the
      # profile configures it; Mendix 10 only the configured ones.
      def offline_configs(profile)
        configured = array(profile['OfflineEntityConfigs']).map { node(_1) }
        return configured if major_version < 11

        known = configured.to_h { [_1['Entity'], _1] }
        (@synchronized.names | known.keys).sort_by(&:downcase).map do |entity|
          known.fetch(entity) { default_config(profile, entity, known) }
        end
      end

      # An entity the profile does not configure is online, unless it
      # specializes a configured entity: Mendix 11 then keeps it out of the
      # synchronization and preserves its data.
      def default_config(profile, entity, known)
        mode = @synchronized.generalizations(entity).any? { known.key?(_1) } ? 'NoneAndPreserveData' : 'Online'
        node('$ID' => derived_id(profile, "offline:#{entity}"), '$Type' => 'Navigation$OfflineEntityConfig',
             'Entity' => entity, 'SyncMode' => mode, 'Constraint' => '', 'CompatibilityMode' => false)
      end

      def major_version = Integer(@source.version.to_s.split('.').first)
    end
  end
end
