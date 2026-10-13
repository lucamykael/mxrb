# frozen_string_literal: true

module Mxrb
  module Dsl
    class ModuleBuilder # rubocop:disable Metrics/ClassLength
      include NativeFragmentAccess
      include IntegrationDocuments
      include CodeActions
      include Workflows
      include PresentationDocuments
      include AssetDocuments
      include ArtifactDocuments

      attr_reader :name, :entities, :pages, :microflows, :nanoflows, :repositories,
                  :associations, :menus, :module_roles, :enumerations, :constants,
                  :scheduled_events, :rules, :rest_response_metadata,
                  :native_documents, :managed_native_document_types

      def initialize(name, flow_metadata: {}, preserve_native_pages: false)
        @name             = name.to_s
        @flow_metadata    = flow_metadata
        @flow_metadata_offsets = Hash.new(0)
        @preserve_native_pages = preserve_native_pages
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
        @rules = []
        @rest_response_metadata = []
        @native_documents = []
        @managed_native_document_types = []
      end

      def entity(name, &block)
        eb = EntityBuilder.new(name)
        eb.instance_eval(&block) if block
        @entities << eb.to_h
      end

      def page(name, public: false, unit_id: nil, &block)
        return if @preserve_native_pages

        default_layout = "#{@name}.ApplicationLayout"
        pb = PageBuilder.new(name, default_layout:, public:, unit_id:)
        pb.instance_eval(&block) if block
        page = pb.to_h
        if page[:forms_model].nil? && page.fetch(:layout) == default_layout
          if page[:popup_options]
            page[:layout] = ensure_popup_layout(page.fetch(:popup_options).fetch(:mode))
          else
            ensure_application_layout
          end
        end
        @pages << page
      end

      def menu(name, &block)
        mb = MenuBuilder.new(name)
        mb.instance_eval(&block) if block
        @menus << mb.to_h
      end

      def module_role(name, id: nil, description: '')
        @module_roles << { name: name.to_s, id: id.to_s, description: description.to_s }
      end

      def microflow(name, kind: :use_case, public: false, unit_id: nil, &block)
        fb = FlowBuilder.new(
          name, runtime: :server, kind: kind, public: public, unit_id:,
                metadata: flow_metadata_for(name, 'Microflows$Microflow')
        )
        fb.instance_eval(&block) if block
        @microflows << fb.to_h
      end

      def nanoflow(name, public: false, unit_id: nil, &block)
        fb = FlowBuilder.new(
          name, runtime: :client, kind: :client_action, public: public, unit_id:,
                metadata: flow_metadata_for(name, 'Microflows$Nanoflow')
        )
        fb.instance_eval(&block) if block
        @nanoflows << fb.to_h
      end

      def rule(name, unit_id: nil, export_level: 'Hidden', &block)
        fb = FlowBuilder.new(
          name, runtime: :server, kind: :rule, public: false, unit_id:,
                metadata: flow_metadata_for(name, 'Microflows$Rule')
        )
        fb.instance_eval(&block) if block
        @rules << fb.to_h.merge(export_level: export_level.to_s)
      end

      def query(name, public: false, unit_id: nil, &block)
        microflow(name, kind: :query, public: public, unit_id:, &block)
      end

      def repository(name, implementation: nil, public: false, documentation: '')
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

      def scheduled_event(name, microflow:, interval: 1, unit: :days, enabled: true, **options, &block)
        sb = ScheduledEventBuilder.new(
          name, microflow: microflow, interval: interval, unit: unit, enabled: enabled, **options
        )
        sb.instance_eval(&block) if block
        @scheduled_events << sb.to_h
      end

      def native_document(name, type:, deep_structure:, containment: 'Documents',
                          unit_id: nil, container_id: nil)
        raise ArgumentError, 'deep_structure requires a Hash' unless deep_structure.is_a?(Hash)

        identity = deep_structure['$ID'] || deep_structure[:'$ID']
        document = {}
        document['$ID'] = identity if identity
        document['$Type'] = type.to_s
        document['Name'] = name.to_s
        document.merge!(deep_structure.except('$ID', :'$ID', '$Type', :'$Type', 'Name', :Name))
        @native_documents << {
          name: name.to_s, type: type.to_s, containment: containment.to_s,
          unit_id: unit_id&.to_s, container_id: container_id&.to_s,
          doc: document
        }
      end

      def flow_metadata_for(name, native_type = 'Microflows$Microflow')
        key = name.to_s
        metadata = @flow_metadata[key]
        return metadata unless metadata.is_a?(Array)

        candidates = metadata.select do |entry|
          stored_type = entry['native_type'].to_s
          stored_type.empty? || stored_type == native_type
        end
        offset_key = [key, native_type]
        offset = @flow_metadata_offsets[offset_key]
        @flow_metadata_offsets[offset_key] += 1
        candidates[offset]
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

      def ensure_popup_layout(mode)
        layout_type = { 'modal' => :modal_popup, 'popup' => :popup }.fetch(mode)
        layout_name = mode == 'modal' ? 'ModalPopupLayout' : 'PopupLayout'
        unless @native_documents.any? { _1[:type] == 'Forms$Layout' && _1[:name] == layout_name }
          node = Forms::Node.build(:layout) do
            name layout_name
            content(:web_layout_content) do
              layout_type layout_type
              widgets(:placeholder) { name 'Main' }
            end
          end
          native_document(layout_name, type: 'Forms$Layout', deep_structure: Forms::MprCodec.new.encode(node))
        end
        "#{@name}.#{layout_name}"
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
          rules: @rules,
          repositories: @repositories, menus: @menus, module_roles: @module_roles,
          enumerations: @enumerations, constants: @constants,
          scheduled_events: @scheduled_events, native_documents: @native_documents,
          rest_responses: @rest_response_metadata,
          managed_native_document_types: @managed_native_document_types
        }
      end
    end

    class MenuBuilder
      include PresentationValues
      include NativeFragmentAccess

      def initialize(name)
        @name  = name.to_s
        @items = []
        @deep_structure = nil
        @unit_id = nil
        @documentation = ''
        @excluded = false
        @export_level = 'Hidden'
      end

      def documentation(value) = (@documentation = value.to_s)
      def excluded(value = true) = (@excluded = value == true)
      def export_level(value) = (@export_level = value.to_s)

      def deep_structure(value)
        raise ArgumentError, 'deep_structure requires a Hash' unless value.is_a?(Hash)

        @deep_structure = value
      end

      def form_structure(value)
        raise ArgumentError, 'form_structure requires a Hash' unless value.is_a?(Hash)

        @deep_structure = presentation_value_document(value)
      end

      def baseline_menu(unit_id:)
        @unit_id = unit_id.to_s
      end

      def bson_binary(base64, subtype: :generic)
        BSON::Binary.new(Base64.strict_decode64(base64), subtype.to_sym)
      end

      def item(caption, page: nil, microflow: nil, icon: nil, translations: {}, &block)
        child = NavigationMenuItemBuilder.new(
          caption, page:, microflow:, icon:, translations:
        )
        child.instance_eval(&block) if block
        @items << child.to_h
      end

      attr_reader :items

      def to_h
        {
          name: @name, items: @items, deep_structure: @deep_structure, unit_id: @unit_id,
          documentation: @documentation, excluded: @excluded, export_level: @export_level
        }
      end
    end
  end
end
