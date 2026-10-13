# frozen_string_literal: true

module Mxrb
  module RubyApp
    class Exporter
      # rubocop:disable Metrics
      # Exports enumerations, datasets, regular expressions and constants.
      module DocumentExports
        CONSTANT_TYPES = {
          'string' => :string, 'integer' => :integer, 'boolean' => :boolean,
          'decimal' => :decimal, 'datetime' => :datetime
        }.freeze

        private

        def export_enumeration(mod, enumeration, namespace, root)
          name = enumeration['Name'].to_s
          class_name = ruby_constant(name)
          id = native_identifier(enumeration['$ID'])
          qualified = "#{mod.name}.#{name}"
          relative = embedded_identity_path(:enumeration, id) || embedded_enumeration_path(id, qualified) ||
                     File.join('app', 'enumerations', root, "#{underscore(name)}.rb")
          manifest = {
            'name' => qualified,
            'id' => id,
            'ruby_class' => embedded_identity_class(:enumeration, id, "#{namespace}::#{class_name}"),
            'path' => relative,
            'documentation' => enumeration['Documentation'].to_s,
            'values' => native_items(enumeration['Values']).map do |value|
              value_name = value['Name'].to_s
              captions = translated_captions(value['Caption'])
              {
                'name' => value_name, 'id' => native_identifier(value['$ID']),
                'caption' => captions['en_US'] || captions.values.first || value_name,
                'captions' => captions
              }
            end
          }
          write(relative, enumeration_source(namespace, class_name, manifest))
          add_coverage(manifest.fetch('id'), manifest.fetch('name'), 'enumeration', relative,
                       'executable_bidirectional')
          manifest
        end

        def export_dataset(mod, document, namespace, root)
          query = document.dig(:doc, 'Source', 'Query')
          return unless query.is_a?(String)

          id = document.fetch(:id).to_s
          name = document.fetch(:name)
          qualified = "#{mod.name}.#{name}"
          class_name = ruby_constant(name)
          relative = embedded_identity_path(:dataset, id) ||
                     File.join('app', 'datasets', root, "#{underscore(name)}.rb")
          parameters = IO::BsonCodec.parse_array(document.dig(:doc, 'Parameters'))[:items].map { _1.fetch('Name') }
          excluded = document.dig(:doc, 'Excluded') == true
          manifest = { 'name' => qualified, 'id' => id, 'path' => relative, 'parameters' => parameters,
                       'excluded' => excluded, 'ruby_class' => "#{namespace}::Datasets::#{class_name}" }
          write(relative, <<~RUBY)
            # frozen_string_literal: true

            module #{namespace}
              module Datasets
                class #{class_name} < Mxrb::RubyApp::Dataset
                  mendix_name #{qualified.inspect}
                  native_metadata parameters: #{parameters.inspect}, excluded: #{excluded.inspect}
                  oql #{query.inspect}
                end
              end
            end
          RUBY
          add_coverage(id, qualified, 'dataset', relative, 'executable_bidirectional')
          manifest
        end

        def export_regular_expression(mod, document, namespace, root)
          name = document.fetch(:name).to_s
          id = document.fetch(:id).to_s
          qualified = "#{mod.name}.#{name}"
          class_name = ruby_constant(name)
          relative = embedded_identity_path(:regular_expression, id) ||
                     File.join('app', 'regular_expressions', root, "#{underscore(name)}.rb")
          properties = document.fetch(:doc).slice(*RegularExpression::FIELDS.values)
          manifest = {
            'name' => qualified, 'id' => id, 'path' => relative, 'properties' => properties,
            'ruby_class' => embedded_identity_class(:regular_expression, id, "#{namespace}::#{class_name}")
          }
          declarations = properties.map do |property, value|
            field = RegularExpression::FIELDS.key(property)
            "    #{field} #{value.inspect}"
          end
          write(relative, <<~RUBY)
            # frozen_string_literal: true

            module #{namespace}
              class #{class_name} < Mxrb::RubyApp::RegularExpression
                mendix_name #{qualified.inspect}
            #{declarations.join("\n")}
              end
            end
          RUBY
          add_coverage(id, qualified, 'regular_expression', relative, 'executable_bidirectional')
          manifest
        end

        def export_constant(mod, constant, namespace, root)
          name = constant['Name'].to_s
          class_name = ruby_constant(name)
          id = native_identifier(constant['$ID'])
          qualified = "#{mod.name}.#{name}"
          relative = embedded_identity_path(:constant, id) || embedded_constant_path(id, qualified) ||
                     File.join('app', 'constants', root, "#{underscore(name)}.rb")
          exposed = constant['ExposedToClient'] == true
          manifest = {
            'name' => qualified, 'id' => id,
            'ruby_class' => embedded_identity_class(:constant, id, "#{namespace}::#{class_name}"), 'path' => relative,
            'documentation' => constant['Documentation'].to_s,
            'type' => constant_type(constant).to_s,
            'exposed_to_client' => exposed, 'excluded' => constant['Excluded'] == true,
            'export_level' => (constant['ExportLevel'] || 'Hidden').to_s,
            'default_redacted' => !exposed
          }
          manifest['default'] = constant['DefaultValue'].to_s if exposed
          write(relative, constant_source(namespace, class_name, manifest))
          add_coverage(id, qualified, 'constant', relative, 'executable_bidirectional')
          manifest
        end

        def embedded_constant_path(id, qualified)
          Array(@embedded_sources).find do |file|
            next unless file.fetch(:path).match?(%r{\Aapp/constants/.+\.rb\z})

            source = file.fetch(:contents).to_s
            matches_id = source.match?(
              /^\s*mendix_name\s+['"][^'"]+['"],\s+id:\s+['"]#{Regexp.escape(id)}['"]/
            )
            matches_id ||
              source.match?(/^\s*mendix_name\s+['"]#{Regexp.escape(qualified)}['"]/)
          end&.fetch(:path)
        end

        def constant_type(constant)
          raw = constant.dig('Type', '$Type') || constant['DataType']
          normalized = raw.to_s.delete_prefix('DataTypes$').delete_suffix('Type').downcase
          CONSTANT_TYPES.fetch(normalized) do
            raise ValidationError,
                  "unsupported native constant type #{raw.inspect} for #{constant['Name']}"
          end
        end

        def embedded_enumeration_path(id, qualified)
          Array(@embedded_sources).find do |file|
            next unless file.fetch(:path).match?(%r{\Aapp/enumerations/.+\.rb\z})

            source = file.fetch(:contents).to_s
            source.match?(
              /^\s*mendix_name\s+['"][^'"]+['"],\s+id:\s+['"]#{Regexp.escape(id)}['"]/
            ) || source.match?(/^\s*mendix_name\s+['"]#{Regexp.escape(qualified)}['"]/)
          end&.fetch(:path)
        end

        def embedded_security_path(id, name, module_security: false)
          Array(@embedded_sources).find do |file|
            next unless file.fetch(:path).match?(%r{\Aapp/security/.+\.rb\z})

            source = file.fetch(:contents).to_s
            id_match = !id.to_s.empty? && source.match?(
              /^\s*(?:mendix_name\s+['"][^'"]+['"],\s+id:|mendix_id)\s+['"]#{Regexp.escape(id)}['"]/
            )
            name_match = module_security && source.match?(
              /^\s*mendix_name\s+['"]#{Regexp.escape(name.to_s)}['"]/
            )
            id_match || name_match
          end&.fetch(:path)
        end

        def embedded_scheduled_event_path(id, qualified)
          Array(@embedded_sources).find do |file|
            next unless file.fetch(:path).match?(%r{\Aapp/scheduled_events/.+\.rb\z})

            source = file.fetch(:contents).to_s
            id_match = !id.to_s.empty? && source.match?(
              /^\s*mendix_name\s+['"][^'"]+['"],\s+id:\s+['"]#{Regexp.escape(id)}['"]/
            )
            id_match || source.match?(
              /^\s*mendix_name\s+['"]#{Regexp.escape(qualified)}['"]/
            )
          end&.fetch(:path)
        end

        def scheduled_event_start(value)
          return value.utc.iso8601 if value.respond_to?(:utc) && value.respond_to?(:iso8601)

          value.to_s
        end

        def translated_caption(caption, fallback)
          text = translated_captions(caption).values.first.to_s
          text.empty? ? fallback : text
        end

        def translated_captions(caption)
          native_items(caption.is_a?(Hash) ? caption['Items'] : nil).filter_map do |translation|
            next unless translation.is_a?(Hash)

            language = translation['LanguageCode'].to_s
            next if language.empty?

            [language, translation['Text'].to_s]
          end.to_h
        end
      end
      # rubocop:enable Metrics
    end
  end
end
