# frozen_string_literal: true

module Mxrb
  module Compiler
    # Compiles the navigation document as MxBuild writes it: each profile with
    # the fields of the version's Runtime schema, the widgets the web documents
    # use and, for a native profile, the offline configuration of every entity
    # the app synchronizes.
    class NavigationDocumentCompiler
      include ModelValues

      NATIVE_PROFILE = 'Navigation$NativeNavigationProfile'
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
        @synchronized = SynchronizedEntities.new(source)
      end

      def compile(unit)
        document = unit.document
        node(document, 'Profiles' => array(document['Profiles']).map { profile(_1) },
                       'PluginWidgets' => @widgets.ids(plugin: true),
                       'CustomWidgetModules' => @widgets.ids(plugin: false))
      end

      private

      # A document with the fields the Runtime schema lists: given, taken from
      # the MPR, or derived as MxBuild does; the seed's counterpart fills a field
      # an older MPR lacks.
      def node(source, given = {})
        existing = @schema.counterpart(source) || {}
        @schema.fields_for(source).to_h do |field|
          value = if given.key?(field) then given[field]
                  elsif field == 'TitleOverride' && source['$Type'] == 'Forms$FormSettings' then title_override(source)
                  elsif source.key?(field) then compile_value(source[field])
                  else derived(source, field, existing)
                  end
          [field, value]
        end
      end

      # Studio Pro keeps a title override whose template says nothing; MxBuild writes none.
      def title_override(settings)
        template = settings['TitleOverride']
        return compile_value(template) if template.nil? || array(template['Parameters']).any?

        array(template.dig('Text', 'Items')).any? { !_1['Text'].to_s.empty? } ? compile_value(template) : nil
      end

      def compile_value(value)
        case value
        when Hash then value['$Type'] ? node(value) : value.transform_values { compile_value(_1) }
        when Array then array(value).map { compile_value(_1) }
        else value
        end
      end

      # What MxBuild writes for a field the MPR leaves out.
      def derived(source, field, existing)
        return existing[field] if existing.key?(field)

        case [source['$Type'], field]
        when ['Forms$FormSettings', 'Location'] then @page_locations.fetch(source['Form'].to_s, 'Content')
        # The legacy data grids of the web documents are not collected yet.
        when ['Navigation$NavigationDocument', 'Grids'] then []
        when [WEB_PROFILE, 'AppTitle'] then { '$ID' => derived_id(source, 'app-title'), '$Type' => 'Texts$Text' }
        when [WEB_PROFILE, 'LoginPageSettings'] then login_page_settings(source)
        else profile_default(source, field)
        end
      end

      def profile_default(source, field)
        return PROFILE_DEFAULTS[field] if source['$Type'] == WEB_PROFILE && PROFILE_DEFAULTS.key?(field)

        raise CompilationError, "cannot derive Runtime field #{source['$Type']}.#{field}"
      end

      def login_page_settings(profile)
        node('$ID' => derived_id(profile, 'login-page'), '$Type' => 'Forms$FormSettings', 'TitleOverride' => nil,
             'ParameterMappings' => [], 'Form' => '')
      end

      # A native profile is offline; a web one only when its kind says so.
      def profile(source)
        native = source['$Type'] == NATIVE_PROFILE
        node(source, 'OfflineEntityConfigsRuntime' => native ? offline_configs(source) : [],
                     'IsOffline' => native || source['Kind'] == 'Offline')
      end

      # Mendix 11 synchronizes every persistable entity, online unless the
      # profile configures it; Mendix 10 only the configured ones.
      def offline_configs(profile)
        configured = array(profile['OfflineEntityConfigs']).map { node(_1) }
        return configured if major_version < 11

        known = configured.to_h { [_1['Entity'], _1] }
        (@synchronized.names | known.keys).sort_by(&:downcase).map do |entity|
          known.fetch(entity) { online_config(profile, entity) }
        end
      end

      def online_config(profile, entity)
        node('$ID' => derived_id(profile, "offline:#{entity}"), '$Type' => 'Navigation$OfflineEntityConfig',
             'Entity' => entity, 'SyncMode' => 'Online', 'Constraint' => '', 'CompatibilityMode' => false)
      end

      def major_version = Integer(@source.version.to_s.split('.').first)
    end
  end
end
