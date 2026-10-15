# frozen_string_literal: true

require 'digest'

module Mxrb
  module RubyApp
    # MxModelReflection.SyncObjects, enabled only for the audited sources of the
    # action and its metamodel builders. It ports Builder, MetaObjectBuilder and
    # MicroflowBuilder step by step over the application's Metamodel.
    module KnownMxModelReflectionActions
      RELEASES = {
        '6.2.0' => {
          'actions/SyncObjects' => '634cb49a24fc32e331f6fcdb8c8c514008b44d9f1e5a01e8ff406252338692f1',
          'metamodelBuilder/Builder' => '51740fddf0dcea8c0869240a0606683f116be8ff08b848d986af5266e3020f72',
          'metamodelBuilder/MetaObjectBuilder' => '58193dc2a91d3e938b8acf7d0ecc2cb59ad6680506095bcac8543fe9ab3bb59a',
          'metamodelBuilder/MicroflowBuilder' => 'be1c24119d18743a03b25f1cb9d115f114df67934d92de0eb326731df7177c26',
          'MxTypeConverter' => '1858064a31773030f424bb6ab67719536c857a3000ab9e44d37616bfb3cc0bff'
        },
        '8.0.2' => {
          'actions/SyncObjects' => '618f87acd58e75c32ebcbc6af47b9ba6773012558bc8625c5ad9a92c696cf391',
          'metamodelBuilder/Builder' => '6614c78b5f3cb7f9a8ed51091508abbe2e19108e6921e8044fbe57f829695d18',
          'metamodelBuilder/MetaObjectBuilder' => '82a02a15f14855bec92c6adc122782289d943bf63dc9c31a703cd17ebfb025e6',
          'metamodelBuilder/MicroflowBuilder' => '3fb8fa129d20f2a5cbadbd1f943288931ed67b018d54d815283f7b84f25dad3d',
          'MxTypeConverter' => '1858064a31773030f424bb6ab67719536c857a3000ab9e44d37616bfb3cc0bff'
        }
      }.freeze

      module_function

      def registrations(directory)
        root = File.join(directory, 'javasource', 'mxmodelreflection')
        release = RELEASES.find do |_, sources|
          sources.all? do |path, hash|
            file = File.join(root, "#{path}.java")
            File.file?(file) && Digest::SHA256.hexdigest(File.binread(file).gsub("\r\n", "\n")) == hash
          end
        end&.first
        release ? "Mxrb::RubyApp::KnownMxModelReflectionActions.register(#{release.inspect})" : ''
      end

      def register(release)
        RELEASES.fetch(release)
        Registry.register_java_custom_action('MxModelReflection.SyncObjects', with_context: true) do |_, context:|
          SyncObjects.new(context).run
        end
      end

      # A port of SyncObjects: Builder, MetaObjectBuilder and MicroflowBuilder.
      # rubocop:disable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity, Metrics/MethodLength
      class SyncObjects
        PREFIX = 'MxModelReflection.'
        PRIMITIVE_TYPES = {
          'String' => 'StringType', 'AutoNumber' => 'AutoNumber', 'Boolean' => 'BooleanType',
          'Decimal' => 'Decimal', 'DateTime' => 'DateTime', 'Enum' => 'EnumType', 'HashString' => 'HashString',
          'Integer' => 'IntegerType', 'Long' => 'LongType', 'Float' => 'FloatType', 'Currency' => 'Currency'
        }.freeze
        DATA_TYPES = {
          'String' => 'StringType', 'AutoNumber' => 'AutoNumber', 'Boolean' => 'BooleanType',
          'Datetime' => 'DateTime', 'Enumeration' => 'EnumType', 'HashString' => 'HashString',
          'Integer' => 'IntegerType', 'Long' => 'LongType', 'Decimal' => 'Decimal'
        }.freeze

        def initialize(context)
          project = context.project
          raise NativeRuntimeError, 'MxModelReflection.SyncObjects needs an exported Ruby application' unless
            project.is_a?(RuntimeProject)

          @store = context.store
          @metamodel = Metamodel.new(project)
          @objects = @metamodel.objects.to_h { [_1.fetch('name'), _1] }
          @module_map = {}
          @active_modules = []
          @all_new_modules = false
        end

        def run
          cache_modules
          build_meta_objects
          build_microflows
          remove_inactive_modules
          true
        end

        private

        def all(entity) = @store.retrieve("#{PREFIX}#{entity}")
        def create(entity) = @store.create("#{PREFIX}#{entity}")
        def commit(values) = Array(values).empty? ? nil : @store.commit(values)
        def delete(value) = @store.delete(value)

        # Builder

        def cache_modules
          modules = all('Module')
          @all_new_modules = true if modules.empty?
          modules.each do |object|
            name = object.members['ModuleName']
            @module_map[name] = object.members['SynchronizeObjectsWithinModule'] ? object : nil
          end
        end

        def validate_module(name)
          @active_modules << name
          unless @module_map.key?(name)
            @module_map[name] = nil
            object = create('Module')
            object.members['ModuleName'] = name
            if @all_new_modules
              @module_map[name] = object
              object.members['SynchronizeObjectsWithinModule'] = true
            end
            commit(object)
          end
          @module_map[name]
        end

        def remove_inactive_modules
          @module_map.each do |name, object|
            next if @active_modules.include?(name)

            delete(object || all('Module').find { _1.members['ModuleName'] == name })
          end
          @module_map.clear
          @active_modules.clear
        end

        def remove_deleted(objects) = objects.each_value { delete(_1) }

        def type_id(datatype)
          name = if datatype.fetch('type') == 'Enumeration' then 'Enum'
                 elsif datatype.fetch('list') then "List of type: #{datatype.fetch('object')}"
                 elsif datatype.fetch('mendix_object') then "Object of type: #{datatype.fetch('object')}"
                 else datatype.fetch('dsl')
                 end
          existing = all('ValueType').find { _1.members['Name'] == name }
          return existing if existing

          value_type = create('ValueType')
          value_type.members.merge!('Name' => name, 'ValueType_MxObjectType' => object_type_id(datatype),
                                    'TypeEnum' => data_type_enum(datatype))
          commit(value_type)
          value_type
        end

        def object_type_id(datatype)
          return unless datatype.fetch('mendix_object') || datatype.fetch('list')

          all('MxObjectType').find { _1.members['CompleteName'] == datatype.fetch('object') }
        end

        def data_type_enum(datatype)
          return 'ObjectList' if datatype.fetch('list')
          return 'ObjectType' if datatype.fetch('mendix_object')

          DATA_TYPES[datatype.fetch('type')]
        end

        # MetaObjectBuilder

        def build_meta_objects
          @languages = @store.retrieve('System.Language').map { _1.members['Code'] }
          existing = all('MxObjectType').to_h { [_1.members['CompleteName'], _1] }
          @all_new_modules = !existing.empty? if @all_new_modules
          @objects.each_value do |meta|
            next unless validate_module(meta.fetch('module'))

            object = handle_object(existing, meta)
            handle_members(meta, object) if object
          end

          associations = all('MxObjectReference').to_h do
            ["#{_1.members['CompleteName']}/#{_1.members['ParentEntity']}", _1]
          end
          processed = []
          references = []
          @metamodel.associations.each do |association|
            next unless validate_module(association.fetch('parent').split('.', 2).first)

            processed << "#{association.fetch('name')}/#{association.fetch('parent')}"
            references << handle_reference(existing, associations, association)
          end
          commit(references)
          processed.each { associations.delete(_1) }
          remove_deleted(associations)

          @objects.each_value { existing.delete(_1.fetch('name')) if validate_module(_1.fetch('module')) }
          remove_deleted(existing)
        end

        def handle_object(existing, meta)
          name = meta.fetch('name')
          if !existing.key?(name) && !@all_new_modules
            object = create('MxObjectType')
            existing[name] = object
            object.members.merge!('CompleteName' => name, 'Name' => name.split('.', 2).last,
                                  'Module' => name.split('.', 2).first)
          else
            object = existing[name]
          end
          return unless object

          supers = meta.fetch('supers').filter_map { handle_object(existing, @objects.fetch(_1)) }
          object.members['MxObjectType_SubClassOf_MxObjectType'] = supers
          object.members['PersistenceType'] = meta.fetch('persistable') ? 'Persistable' : 'Non_persistent'
          module_object = @module_map[meta.fetch('module')]
          object.members['MxObjectType_Module'] = module_object if module_object
          commit(object)
          object
        end

        def handle_members(meta, object)
          by_name = members_of(object).to_h { [_1.members['AttributeName'], _1] }
          members = []
          meta.fetch('primitives').each do |primitive|
            name = primitive.fetch('name')
            if primitive.fetch('type') == 'Enum'
              current = by_name[name]
              if current&.entity == "#{PREFIX}MxObjectEnum"
                members << handle_enum(current, primitive, object)
                by_name.delete(name)
              else
                delete(by_name.delete(name)) if current
                members << handle_enum(nil, primitive, object)
              end
            else
              members << handle_member(object, by_name, primitive)
            end
          end
          commit(members)
          remove_deleted(by_name)
        end

        def members_of(object)
          (all('MxObjectMember') + all('MxObjectEnum')).uniq(&:id).select do
            _1.members['MxObjectMember_MxObjectType']&.id == object.id
          end
        end

        def handle_member(object, by_name, primitive)
          name = primitive.fetch('name')
          member = by_name.delete(name)
          if member.nil? || member.entity == "#{PREFIX}MxObjectEnum"
            delete(member) if member
            member = create('MxObjectMember')
            member.members.merge!('AttributeName' => name, 'MxObjectMember_MxObjectType' => object)
          end
          member.members.merge!(
            'MxObjectMember_Type' => type_id(primitive.fetch('datatype')), 'AttributeType' => primitive.fetch('type'),
            'AttributeTypeEnum' => PRIMITIVE_TYPES[primitive.fetch('type')],
            'FieldLength' => primitive.fetch('length'), 'IsVirtual' => primitive.fetch('virtual')
          )
          member
        end

        def handle_enum(enum, primitive, object)
          enum ||= create('MxObjectEnum')
          current = Array(enum.members['Values']).to_h { [_1.members['Name'], _1] }
          enumeration = primitive.fetch('datatype').fetch('dsl').delete_prefix('#')
          values = primitive.fetch('enum').map do |meta_value|
            value = current[meta_value.fetch('id')] || create('MxObjectEnumValue')
            by_language = Array(value.members['Captions']).to_h { [_1.members['LanguageCode'], _1] }
            captions = @languages.map do |code|
              caption = by_language[code] || create('MxObjectEnumCaptions')
              caption.members.merge!('Caption' => @metamodel.enum_caption(enumeration, meta_value, code),
                                     'LanguageCode' => code)
              caption
            end
            value.members.merge!('Name' => meta_value.fetch('id'), 'Captions' => captions)
            commit(captions)
            value
          end
          current.each_value { delete(_1) unless values.include?(_1) }
          enum.members.merge!(
            'Values' => values, 'AttributeName' => primitive.fetch('name'), 'AttributeType' => primitive.fetch('type'),
            'AttributeTypeEnum' => 'EnumType', 'MxObjectMember_MxObjectType' => object,
            'MxObjectMember_Type' => type_id(primitive.fetch('datatype'))
          )
          commit(values)
          enum
        end

        def handle_reference(existing, associations, association)
          name = association.fetch('name')
          parent_name = association.fetch('parent')
          reference = associations["#{name}/#{parent_name}"]
          unless reference
            reference = create('MxObjectReference')
            reference.members.merge!('CompleteName' => name, 'ParentEntity' => parent_name)
          end
          parents = hierarchy(existing, parent_name)
          children = hierarchy(existing, association.fetch('child'))
          reference.members.merge!(
            'MxObjectReference_MxObjectType' => children + parents, 'MxObjectReference_MxObjectType_Child' => children,
            'MxObjectReference_MxObjectType_Parent' => parents, 'Name' => name.split('.', 2).last,
            'Module' => name.split('.', 2).first,
            'ReferenceType' => association.fetch('type') == 'REFERENCE' ? 'Reference' : 'ReferenceSet',
            'AssociationOwner' => association.fetch('owner') == 'DEFAULT' ? '_Default' : 'Both',
            'MxObjectReference_Module' => @module_map.fetch(parent_name.split('.', 2).first)
          )
          reference
        end

        def hierarchy(existing, name)
          meta = @objects.fetch(name)
          [meta, *meta.fetch('subs').map { @objects.fetch(_1) }].filter_map { handle_object(existing, _1) }
        end

        # MicroflowBuilder

        def build_microflows
          existing = all('Microflows').to_h { [_1.members['CompleteName'], _1] }
          @all_new_modules = !existing.empty? if @all_new_modules
          parameters = []
          microflows = []
          @metamodel.microflows.each do |meta|
            name = meta.fetch('name')
            module_name = name.split('.', 2).first
            next unless validate_module(module_name)

            microflow = existing.delete(name)
            unless microflow
              microflow = create('Microflows')
              microflow.members.merge!('CompleteName' => name, 'Name' => name.split('.', 2).last,
                                       'Module' => module_name)
              microflow.members['Microflows_Module'] = @module_map.fetch(module_name)
            end
            parameters.concat(handle_parameters(meta, microflow))
            microflows << microflow
          end
          commit(parameters)
          commit(microflows)
          remove_deleted(existing)
        end

        def handle_parameters(meta, microflow)
          existing = Array(microflow.members['Microflows_InputParameter']).to_h { [_1.members['Name'], _1] }
          parameters = meta.fetch('parameters').map do |entry|
            parameter = existing.delete(entry.fetch('name')) || create('Parameter')
            parameter.members.merge!('Name' => entry.fetch('name'),
                                     'Parameter_ValueType' => type_id(entry.fetch('datatype')),
                                     'Parameter_MxObjectType' => object_type_id(entry.fetch('datatype')))
            parameter
          end
          microflow.members['Microflows_Output_Type'] = type_id(meta.fetch('return'))
          microflow.members['Microflows_InputParameter'] = parameters
          remove_deleted(existing)
          parameters
        end
      end
      # rubocop:enable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity, Metrics/MethodLength
    end
  end
end
