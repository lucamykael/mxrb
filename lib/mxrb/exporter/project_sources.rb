# frozen_string_literal: true

module Mxrb
  class Exporter
    # Writes project.rb, module sources, security, navigation and the design system.
    module ProjectSources
      private

      def write_project(project, ruby_sources: false)
        module_loads = project.modules.map do |mod|
          %(  evaluate File.join(__dir__, "modules", #{ruby(mod.name)}, "module.rb"))
        end.join("\n")

        source = <<~RUBY
            # frozen_string_literal: true

            require "mxrb" unless defined?(Mxrb::Dsl)

            output = ENV.fetch("MXRB_OUTPUT_PATH", File.join(__dir__, #{ruby(File.basename(@mpr_path))}))

            Mxrb.define(output) do
              mendix_version #{ruby(project.mendix_version || '10.18.0')}
              mendix_project_id #{ruby(project.mpr.root_unit.fetch('UnitID'))}
              native_units File.join(__dir__, ".mxrb", "native_units.json")
              semantic_metadata File.join(__dir__, ".mxrb", "semantic_metadata.json")
              native_fragments File.join(__dir__, ".mxrb", "native_fragments")
              project_assets File.join(__dir__, ".mxrb", "assets.json"), root: __dir__
          #{'    ruby_app_sources File.join(__dir__, ".mxrb", "ruby_sources.json")' if ruby_sources}
              evaluate File.join(__dir__, ".mxrb", "widget_types.rb")
              evaluate File.join(__dir__, ".mxrb", "native_units.rb")
              evaluate File.join(__dir__, "app", "security", "security.rb")
              evaluate File.join(__dir__, "app", "navigation", "navigation.rb")
              evaluate File.join(__dir__, "app", "design_system", "design_system.rb")
              evaluate File.join(__dir__, "app", "settings", "settings.rb")
              evaluate File.join(__dir__, "app", "texts", "system_texts.rb")
          #{module_loads}
            end
        RUBY
        write(File.join(@output_dir, 'project.rb'), source)
      end

      def module_source(mod)
        <<~RUBY
          # frozen_string_literal: true

          self.module #{symbol(mod.name)} do
            evaluate File.join(__dir__, "domain", "model.rb")
            evaluate File.join(__dir__, "application", "application.rb")
            evaluate File.join(__dir__, "presentation", "presentation.rb")
            evaluate File.join(__dir__, "infrastructure", "infrastructure.rb")
            evaluate File.join(__dir__, "security", "security.rb")
          end
        RUBY
      end

      def project_security_doc(project)
        raw = project.all_units.find { |unit| project.parse_bson(unit)['$Type'] == 'Security$ProjectSecurity' }
        raw && project.parse_bson(raw)
      end

      def security_source(doc)
        level = doc['SecurityLevel']
        roles = IO::BsonCodec.parse_array(doc['UserRoles']).fetch(:items).map do |role|
          module_roles = IO::BsonCodec.parse_array(role['ModuleRoles']).fetch(:items)
          args = [symbol(role.fetch('Name'))]
          manageable = IO::BsonCodec.parse_array(role['ManageableRoles']).fetch(:items)
          args << "description: #{ruby(role['Description'].to_s)}" unless role['Description'].to_s.empty?
          args << 'check_security: false' unless role['CheckSecurity'] == true
          args << "manageable_roles: #{ruby(manageable)}" unless manageable.empty?
          # An explicit empty list is semantically different from a Ruby-first
          # declaration, where the DSL supplies the conventional System role.
          args << "module_roles: #{ruby(module_roles)}"
          args << 'exact_module_roles: true'
          args << 'admin: true' if role['ManageAllRoles'] == true
          args << 'manage_users_without_roles: true' if role['ManageUsersWithoutRoles'] == true
          "  user_role #{args.join(', ')}"
        end
        options = []
        options << "  check_security #{doc.fetch('CheckSecurity', true) == true}"
        options << "  strict_page_url_check #{doc.fetch('StrictPageUrlCheck', true) == true}"
        options << "  admin_user #{ruby(doc.fetch('AdminUserName', 'MxAdmin'))}"
        options << "  admin_user_role #{ruby(doc['AdminUserRole'])}" unless doc['AdminUserRole'].to_s.empty?
        options << "  demo_users #{doc['EnableDemoUsers'] == true}"
        demo_users = doc['DemoUsers'] || IO::BsonCodec.build_array([])
        IO::BsonCodec.parse_array(demo_users).fetch(:items).each do |user|
          assigned_roles = IO::BsonCodec.parse_array(user['UserRoles']).fetch(:items)
          options << "  demo_user #{ruby(user['UserName'])}, entity: #{ruby(user['Entity'])}, " \
                     "roles: #{ruby(assigned_roles)}, password: #{ruby(user['Password'])}"
        end
        guest = "  guest_access #{doc['EnableGuestAccess'] == true}"
        guest += ", role: #{ruby(doc['GuestUserRole'])}" unless doc['GuestUserRole'].to_s.empty?
        options << guest
        options << "  strict_mode #{doc.fetch('StrictMode', false) == true}"
        options.concat(project_access_source(doc, 'FileDocumentAccess', 'file_document_access_rule',
                                             'clear_file_document_access_rules!'))
        options.concat(project_access_source(doc, 'ImageAccess', 'image_access_rule',
                                             'clear_image_access_rules!'))
        options << "  sign_in_microflow #{ruby(doc['SignInMicroflow'])}" unless doc['SignInMicroflow'].to_s.empty?
        password = doc['PasswordPolicySettings']
        if password.is_a?(Hash)
          known = {
            'MinimumLength' => :minimum_length,
            'RequireDigit' => :require_digit,
            'RequireMixedCase' => :require_mixed_case,
            'RequireSymbol' => :require_symbol
          }
          policy = password.each_with_object({}) do |(key, value), result|
            next if %w[$ID $Type].include?(key)

            result[known.fetch(key, key.to_sym)] = value
          end
          arguments = policy.map do |key, value|
            label = key.to_s.match?(/\A[a-z_][a-z0-9_]*\z/) ? "#{key}:" : "#{ruby(key.to_s)}:"
            "#{label} #{ruby(value)}"
          end
          options << "  password_policy(#{arguments.join(', ')})"
        end
        <<~RUBY
            # frozen_string_literal: true

            security do
              security_level #{ruby(level)}
          #{roles.join("\n")}
          #{options.join("\n")}
            end
        RUBY
      end

      def project_access_source(document, native_key, declaration, clear_declaration)
        container = document[native_key]
        return [] unless container.is_a?(Hash)

        native_rules = IO::BsonCodec.parse_array(container['AccessRules']).fetch(:items)
        rules = native_rules.filter_map do |rule|
          next unless rule.is_a?(Hash) && rule['$Type'] == 'DomainModels$AccessRule'

          access_rule_source(Model::Entity.parse_access_rule(rule))&.sub(
            /\A  access_rule/, "  #{declaration}"
          )
        end
        return [] unless rules.size == native_rules.size

        rules.empty? ? ["  #{clear_declaration}"] : rules
      end

      def navigation_source(navigation)
        return "# frozen_string_literal: true\n" unless navigation

        profiles = navigation.fetch(:profiles, []).flat_map { navigation_profile_source(_1) }
        "# frozen_string_literal: true\n\nnavigation do\n#{profiles.join("\n")}\nend\n"
      end

      def navigation_profile_source(profile)
        return native_navigation_profile_source(profile) if profile[:kind].to_s == 'Native'

        args = [symbol(profile.fetch(:name))]
        args << "home_page: #{ruby(profile[:home_page])}" if profile[:home_page]
        args << "home_microflow: #{ruby(profile[:home_microflow])}" if profile[:home_microflow]
        args << "sign_in_page: #{ruby(profile[:sign_in_page])}" if profile[:sign_in_page]
        args << "sign_in_title: #{ruby(profile[:sign_in_title])}" unless
          profile.fetch(:sign_in_title, {}).empty?
        args << "sign_in_location: #{ruby(profile[:sign_in_location])}" if profile[:sign_in_location]
        args << "not_found_page: #{ruby(profile[:not_found_page])}" if profile[:not_found_page]
        args << "not_found_microflow: #{ruby(profile[:not_found_microflow])}" if profile[:not_found_microflow]
        args << "menu: #{ruby(profile[:menu])}" if profile[:menu]
        role_homes = profile.fetch(:role_homes, {})
        args << "role_homes: #{ruby(role_homes)}" if role_homes.is_a?(Hash) && !role_homes.empty?
        args << 'offline: true' if profile[:offline]
        args << "enabled: #{ruby(profile[:enabled])}" unless profile[:enabled].nil?
        args << "offline_enabled: #{ruby(profile[:offline_enabled])}" unless
          profile[:offline_enabled].nil?
        unless profile[:throw_partial_sync_error].nil?
          args << "throw_partial_sync_error: #{ruby(profile[:throw_partial_sync_error])}"
        end
        args << "kind: #{ruby(profile[:kind])}" unless profile[:kind].to_s.empty?
        args << "app_icon: #{ruby(profile[:app_icon])}" if profile[:app_icon]
        body = navigation_profile_body(profile, role_homes)
        return ["  profile #{args.join(', ')}"] if body.empty?

        ["  profile #{args.join(', ')} do", *body, '  end']
      end

      def native_navigation_profile_source(profile)
        args = [symbol(profile.fetch(:name)), 'kind: "Native"']
        args << "home_page: #{ruby(profile[:home_page])}" if profile[:home_page]
        args << "home_nanoflow: #{ruby(profile[:home_nanoflow])}" if profile[:home_nanoflow]
        unless profile[:throw_partial_sync_error].nil?
          args << "throw_partial_sync_error: #{ruby(profile[:throw_partial_sync_error])}"
        end
        settings = profile.fetch(:settings, {}).reject do |key, value|
          Model::NativeNavigationProfile::SETTING_DEFAULTS[key] == value
        end
        args << "settings: #{ruby(settings)}" unless settings.empty?
        role_homes = profile.fetch(:role_homes, [])
        details = role_homes.is_a?(Array) ? role_homes : role_homes.map { |role, page| { role:, page: } }
        homes = (details + profile.fetch(:role_home_details, [])).map do |home|
          options = %i[page nanoflow].filter_map { "#{_1}: #{ruby(home[_1])}" if home[_1] }
          ["    home_for #{ruby(home.fetch(:role))}", *options].join(', ')
        end
        items = profile.fetch(:bottom_bar, []).map do |item|
          caption = item.fetch(:caption)
          item_args = [ruby(caption['en_US'] || caption.values.first || ''), "page: #{ruby(item.fetch(:page))}"]
          item_args << "icon: #{ruby(item[:icon])}" if item[:icon]
          translations = caption.reject { |locale, _| locale.to_s == 'en_US' }
          item_args << "translations: #{ruby(translations)}" unless translations.empty?
          "    bottom_bar_item #{item_args.join(', ')}"
        end
        body = homes + items + offline_entity_sources(profile)
        return ["  profile #{args.join(', ')}"] if body.empty?

        ["  profile #{args.join(', ')} do", *body, '  end']
      end

      def navigation_profile_body(profile, role_homes)
        details = role_homes.is_a?(Array) ? role_homes : profile.fetch(:role_home_details, [])
        titles = profile.fetch(:app_title, {}).map do |locale, text|
          "    title #{ruby(locale)}, #{ruby(text)}"
        end
        homes = details.map do |home|
          options = []
          options << "page: #{ruby(home[:page])}" if home[:page]
          options << "microflow: #{ruby(home[:microflow])}" if home[:microflow]
          suffix = options.empty? ? '' : ", #{options.join(', ')}"
          "    home_for #{ruby(home.fetch(:role))}#{suffix}"
        end
        items = profile.fetch(:items, []).flat_map { navigation_item_source(_1, 4) }
        extensions = if profile.fetch(:name).to_s == 'Responsive'
                       ['    evaluate_dir File.join(__dir__, "responsive")']
                     else
                       []
                     end
        titles + homes + items + extensions + offline_entity_sources(profile)
      end

      def offline_entity_sources(profile)
        profile.fetch(:offline_entities, []).map do |config|
          mode = config.fetch(:sync_mode, 'None').to_s.gsub(/(?<=[a-z])(?=[A-Z])/, '_').downcase
          args = [ruby(config.fetch(:entity)), "sync_mode: #{symbol(mode)}"]
          args << "constraint: #{ruby(config[:constraint])}" unless config[:constraint].to_s.empty?
          args << 'compatibility_mode: true' if config[:compatibility_mode] == true
          "    offline_entity #{args.join(', ')}"
        end
      end

      def design_system_source(design_system)
        return "# frozen_string_literal: true\n" unless design_system

        lines = design_system.fetch(:tokens, []).map do |token|
          args = [symbol(token.fetch(:name))]
          args << "value: #{ruby(token[:value])}" unless token[:value].nil?
          "  #{token.fetch(:kind)} #{args.join(', ')}"
        end
        lines.concat(design_system.fetch(:layouts, []).map { "  layout #{ruby(_1)}" })
        lines.concat(design_system.fetch(:components, []).map { "  component #{ruby(_1)}" })
        lines.concat(design_system.fetch(:accessibility, []).map { "  accessibility #{ruby(_1)}" })
        design_system.fetch(:themes, []).each do |theme|
          args = [ruby(theme.fetch(:name))]
          args << "inherits: #{ruby(theme[:inherits])}" if theme[:inherits]
          lines << "  theme #{args.join(', ')} do"
          theme.fetch(:tokens, []).each do |token|
            token_args = [symbol(token.fetch(:name))]
            token_args << "value: #{ruby(token[:value])}" unless token[:value].nil?
            lines << "    #{token.fetch(:kind)} #{token_args.join(', ')}"
          end
          lines << '  end'
        end
        design_system.fetch(:contrast_pairs, []).each do |pair|
          lines << "  contrast foreground: #{ruby(pair.fetch(:foreground))}, " \
                   "background: #{ruby(pair.fetch(:background))}, level: #{symbol(pair.fetch(:level))}"
        end
        lines << '  forbid_literal_colors' if design_system[:forbid_literal_colors]
        "# frozen_string_literal: true\n\ndesign_system do\n#{lines.join("\n")}\nend\n"
      end

      def navigation_item_source(item, indent)
        pad = ' ' * indent
        caption = item.fetch(:caption)
        primary = caption['en_US'] || caption[:en_US] || caption.values.first || ''
        translations = caption.reject { |locale, _| locale.to_s == 'en_US' }
        args = [ruby(primary)]
        args << "page: #{ruby(item[:page])}" if item[:page]
        args << "microflow: #{ruby(item[:microflow])}" if item[:microflow]
        args << "icon: #{ruby(item[:icon])}" if item[:icon]
        args << "translations: #{ruby(translations)}" unless translations.empty?
        children = item.fetch(:items, [])
        return ["#{pad}item #{args.join(', ')}"] if children.empty?

        ["#{pad}item #{args.join(', ')} do",
         *children.flat_map { navigation_item_source(_1, indent + 2) },
         "#{pad}end"]
      end
    end
  end
end
