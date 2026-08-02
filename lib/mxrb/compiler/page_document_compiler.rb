# frozen_string_literal: true

module Mxrb
  module Compiler
    # Compiles page routing, parameters, titles, and authorization for the Runtime model.
    class PageDocumentCompiler
      include ModelValues
      include RuntimeDataTypes

      def initialize(source)
        @role_map = project_role_map(source)
      end

      def compile(unit)
        source = unit.document
        raise CompilationError, "unsupported page root #{source['$Type']}" unless source['$Type'] == 'Forms$Page'

        page_fields(source).merge(identity_fields(source, unit.module_name)).merge(popup_fields(source))
      end

      private

      def page_fields(source)
        {
          '$ID' => source['$ID'], '$Type' => source['$Type'],
          'Parameters' => array(source['Parameters']).map { parameter(_1) },
          'Title' => text_reference(source['Title']), 'UrlSegments' => url_segments(source['Url'])
        }
      end

      def parameter(source)
        {
          '$ID' => source['$ID'], '$Type' => source['$Type'], 'Name' => source['Name'],
          'ParameterTypeRuntime' => data_type(source['ParameterType']),
          'IsRequired' => source.fetch('IsRequired', false) == true
        }
      end

      def identity_fields(source, module_name)
        {
          'Name' => source['Name'], 'QualifiedName' => "#{module_name}.#{source['Name']}",
          'ModelerAllowedUserRoles' => allowed_user_roles(source)
        }
      end

      def popup_fields(source)
        {
          'PopupWidth' => source['PopupWidth'].to_i, 'PopupHeight' => source['PopupHeight'].to_i,
          'PopupResizable' => source['PopupResizable'] == true, 'Url' => source['Url'].to_s
        }
      end

      def text_reference(source)
        return nil unless source

        source.slice('$ID', '$Type')
      end

      def url_segments(url)
        url.to_s.split('/').filter_map { _1.start_with?('{') && _1.end_with?('}') ? _1[1..-2] : nil }
      end

      def allowed_user_roles(page)
        array(page['AllowedModuleRoles']).flat_map { @role_map.fetch(_1.to_s, []) }.uniq
      end

      def project_role_map(source)
        security = source.documents('Security$ProjectSecurity').first
        return {} unless security

        array(security['UserRoles']).each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |role, map|
          array(role['ModuleRoles']).each { |module_role| map[module_role.to_s] << role['Name'].to_s }
        end
      end
    end
  end
end
