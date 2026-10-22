# frozen_string_literal: true

module Mxrb
  module Compiler
    # Compiles page routing, parameters, titles, and authorization for the Runtime model.
    class PageDocumentCompiler
      include ModelValues
      include RuntimeDataTypes

      def initialize(source)
        @roles = UserRoleResolver.new(source)
        @url_segments = UrlSegmentCompiler.new(source)
        @typed_parameters = typed_parameters?(source)
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
          'Title' => text_reference(source['Title']), 'UrlSegments' => @url_segments.segments(source)
        }
      end

      # Mendix 11 keeps the type and requirement of a page parameter in the
      # Runtime model; older versions only its name.
      def typed_parameters?(source)
        version = source.respond_to?(:version) ? source.version.to_s : ''
        version.empty? || version.split('.').first.to_i >= 11
      end

      def parameter(source)
        fields = { '$ID' => source['$ID'], '$Type' => source['$Type'], 'Name' => source['Name'] }
        return fields unless @typed_parameters

        fields.merge('ParameterTypeRuntime' => data_type(source['ParameterType']),
                     'IsRequired' => source.fetch('IsRequired', false) == true)
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

      def allowed_user_roles(page) = @roles.resolve(array(page['AllowedModuleRoles']))
    end
  end
end
