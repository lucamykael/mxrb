# frozen_string_literal: true

module Mxrb
  module RubyApp
    # rubocop:disable Metrics
    # Carries edits of an exported Ruby page to its native Mendix document.
    #
    # The Ruby page is a leaner projection of the document, so the document cannot
    # be rebuilt from it. The export keeps the page's source as a baseline. A page
    # still equal to its baseline leaves the document untouched; otherwise the two
    # evaluated pages are compared and only the differences are applied. An edit
    # with no native counterpart here raises instead of being lost.
    class PageEdits
      BASELINE_DIRECTORY = File.join('.mxrb', 'page_baselines')
      CAPTION_PATHS = [%w[caption], %w[options caption]].freeze
      APPEARANCE_PATHS = { %w[options class] => 'Class', %w[options style] => 'Style' }.freeze
      PAGE_APPEARANCE = { appearance_class: 'Class', appearance_style: 'Style' }.freeze
      # The fields that show a widget's caption. Older models repeat it in two of them.
      CAPTION_FIELDS = %w[Caption CaptionTemplate Label LabelTemplate].freeze

      # An edit of a Ruby page that this synchronization cannot apply to the document.
      class UnsupportedEdit < ValidationError; end

      def self.baseline_path(root, unit_id) = File.join(root, BASELINE_DIRECTORY, "#{unit_id}.rb")
      def self.baseline?(root, unit_id) = File.file?(baseline_path(root, unit_id))

      def self.write_baseline(root, unit_id, source_path)
        path = baseline_path(root, unit_id)
        FileUtils.mkdir_p(File.dirname(path))
        FileUtils.cp(source_path, path)
      end

      def initialize(project, manifest)
        @project = project
        @manifest = manifest
        @root = manifest.root
      end

      def apply!
        documents = @project.modules.flat_map(&:pages).to_h { [_1.id, _1] }
        edited = @manifest.modules.flat_map { _1.fetch('pages') }.select { edited?(_1) }
        return if edited.empty?

        @project.mpr.transaction do
          edited.each { apply_page(_1, documents.fetch(_1.fetch('id'))) }
        end
        @project.refresh!
      end

      private

      def edited?(entry)
        return false unless self.class.baseline?(@root, entry.fetch('id'))

        page = Registry.fetch(:page, entry.fetch('name'))
        unsupported!(entry.fetch('name'), 'the page declaration was removed or renamed') unless page
        return false if page.native_definition

        current = File.join(@root, entry.fetch('path'))
        !File.file?(current) ||
          File.binread(current) != File.binread(self.class.baseline_path(@root, entry.fetch('id')))
      end

      def apply_page(entry, document)
        name = entry.fetch('name')
        changes = Comparison.new(name, snapshot(baseline_page(entry)), snapshot(Registry.fetch(:page, name))).changes
        return if changes.empty?

        raw = document.raw_document
        Document.new(name, raw).apply(changes)
        @project.mpr.update_unit(document.id, raw)
      end

      def snapshot(page)
        {
          title: page.title.to_s, appearance_class: page.appearance_class.to_s,
          appearance_style: page.appearance_style.to_s,
          allowed_module_roles: Array(page.allowed_module_roles).map(&:to_s),
          data_source: JSON.parse(JSON.generate(page.data_source)),
          widgets: JSON.parse(JSON.generate(page.widgets))
        }
      end

      # Evaluates the baseline apart from the application's own declarations.
      def baseline_page(entry)
        registered = Registry.snapshot
        Registry.reset!
        evaluate(self.class.baseline_path(@root, entry.fetch('id')))
        Registry.fetch(:page, entry.fetch('name'))
      ensure
        Registry.restore!(registered)
      end

      # Under the same contexts as the application's own sources.
      def evaluate(path)
        SourceIdentity.with(@manifest) do |identities|
          PageDesignIdentity.with(@manifest) do
            PluggableProperties.with(@manifest) do
              RubyApp.with_native_fragments(@root) { identities.load_file(path) { load path, true } }
            end
          end
        end
      end

      def unsupported!(page, reason) = raise(UnsupportedEdit, "#{page}: #{reason}")

      # Compares two evaluated pages and lists the differences that have a native counterpart.
      class Comparison
        attr_reader :changes

        def initialize(page, before, after)
          @page = page
          @changes = []
          %i[allowed_module_roles data_source].each do |field|
            unsupported!(field) unless before.fetch(field) == after.fetch(field)
          end
          compare_scalar_page_fields(before, after)
          compare(before.fetch(:widgets), after.fetch(:widgets), 'widgets', nil, [])
          @changes.uniq!
        end

        private

        def compare_scalar_page_fields(before, after)
          old_title = before.fetch(:title)
          new_title = after.fetch(:title)
          @changes << [:title, old_title, new_title] unless old_title == new_title
          PAGE_APPEARANCE.each do |field, key|
            value = after.fetch(field)
            @changes << [:page_appearance, key, value] unless before.fetch(field) == value
          end
        end

        def compare(before, after, path, widget, relative)
          return if before == after

          if before.is_a?(Hash) && after.is_a?(Hash)
            compare_hashes(before, after, path, widget, relative)
          elsif (before.is_a?(Hash) && after.nil?) || (before.nil? && after.is_a?(Hash))
            compare_hashes(before.to_h, after.to_h, path, widget, relative)
          elsif (before.is_a?(Array) || before.nil?) && (after.is_a?(Array) || after.nil?)
            compare_arrays(before.to_a, after.to_a, path, widget, relative)
          else
            compare_values(before, after, path, widget, relative)
          end
        end

        def compare_hashes(before, after, path, widget, relative)
          if before.key?('type') && after.key?('type')
            compare_widgets(before, after, path)
          else
            (before.keys | after.keys).each do |key|
              compare(before[key], after[key], "#{path}.#{key}", widget, relative + [key])
            end
          end
        end

        def compare_widgets(before, after, path)
          name = after['name'].to_s
          unsupported!("#{path} changed its widget type or name") \
            unless before.values_at('type', 'name') == after.values_at('type', 'name')

          (before.keys | after.keys).each do |key|
            compare(before[key], after[key], "#{path}.#{key}", name, [key])
          end
        end

        def compare_arrays(before, after, path, widget, relative)
          if widget_list?(before) && widget_list?(after)
            compare_widget_lists(before, after, path)
          elsif before.size == after.size
            before.each_index { compare(before[_1], after[_1], "#{path}[#{_1}]", widget, relative + [_1]) }
          else
            unsupported!("#{path} changed in a way that cannot be applied to the document")
          end
        end

        def widget_list?(list)
          names = list.map { _1.is_a?(Hash) && _1.key?('type') ? _1['name'].to_s : '' }
          names.none?(&:empty?) && names.uniq.size == names.size
        end

        def compare_widget_lists(before, after, path)
          names_before = before.map { _1.fetch('name') }
          names_after = after.map { _1.fetch('name') }
          added = names_after - names_before
          unsupported!("#{path} adds #{added.join(', ')}; adding a widget is not supported yet") unless added.empty?

          (names_before - names_after).each { @changes << [:remove, _1] }
          kept = names_before & names_after
          @changes << [:order, names_after] unless kept == names_after
          after.each do |entry|
            previous = before.find { _1.fetch('name') == entry.fetch('name') }
            compare_widgets(previous, entry, "#{path}.#{entry.fetch('name')}")
          end
        end

        def compare_values(before, after, path, widget, relative)
          if widget && CAPTION_PATHS.include?(relative)
            @changes << [:caption, widget, before.to_s, after.to_s]
          elsif widget && APPEARANCE_PATHS.key?(relative)
            @changes << [:appearance, widget, APPEARANCE_PATHS.fetch(relative), after.to_s]
          else
            unsupported!("#{path} changed from #{before.inspect} to #{after.inspect}, " \
                         'which cannot be applied to the document yet')
          end
        end

        def unsupported!(reason) = raise(UnsupportedEdit, "#{@page}: #{reason}")
      end

      # Applies listed differences to the raw document of a page.
      class Document
        def initialize(page, raw)
          @page = page
          @raw = raw
        end

        def apply(changes)
          changes.each { send(*_1) }
        end

        private

        def title(before, after) = replace_text(@raw.fetch('Title'), before, after, 'the page title')

        def page_appearance(key, value) = set_appearance(@raw, key, value, 'the page')

        def appearance(name, key, value) = set_appearance(widget(name), key, value, name)

        # Mendix before 8 keeps the class and style on the widget itself.
        def set_appearance(owner, key, value, label)
          holder = owner['Appearance'] || owner
          unsupported!("#{label} has no #{key} in the document") unless holder.key?(key)

          holder[key] = value
        end

        def caption(name, before, after)
          texts = owner_texts(widget(name)).select { |_field, text| translations(text, before).any? }
          unsupported!("no caption of #{name} reads #{before.inspect} in the document") if texts.empty?

          captions = texts.select { |field, _text| CAPTION_FIELDS.include?(field) }
          unsupported!("more than one text of #{name} reads #{before.inspect}") if captions.empty? && texts.size > 1

          (captions.empty? ? texts : captions).map(&:last).each { replace_text(_1, before, after, name) }
        end

        def remove(name)
          list = list_holding(name)
          list.delete_if { named?(_1, name) }
        end

        def order(names)
          list = list_holding(names.first)
          placed = names.map do |name|
            list.find { named?(_1, name) } || unsupported!("#{name} does not share a parent in the document")
          end
          positions = list.each_index.select { placed.include?(list[_1]) }
          positions.zip(placed).each { |position, entry| list[position] = entry }
        end

        def replace_text(text, before, after, label)
          items = translations(text, before)
          unsupported!("no text of #{label} reads #{before.inspect} in the document") if items.empty?

          items.each { _1['Text'] = after }
        end

        def translations(text, value)
          Array(text['Items']).select { _1.is_a?(Hash) && _1['Text'] == value }
        end

        # The texts that belong to the widget itself, not to the widgets inside it,
        # with the widget field each one is under.
        def owner_texts(value, field = nil, found = [])
          case value
          when Hash
            found << [field, value] if value['$Type'] == 'Texts$Text'
            value.each do |key, entry|
              next if key == 'Fallback' || widget?(entry)

              owner_texts(entry, field || key, found)
            end
          when Array then value.each { owner_texts(_1, field, found) unless widget?(_1) }
          end
          found
        end

        def widget(name)
          widgets = []
          each_value(@raw) { widgets << _1 if named?(_1, name) }
          unsupported!("widget #{name} is not in the document") if widgets.empty?
          unsupported!("more than one element of the document is named #{name}") if widgets.size > 1

          widgets.first
        end

        def list_holding(name)
          each_value(@raw) do |value|
            return value if value.is_a?(Array) && value.any? { named?(_1, name) }
          end
          unsupported!("widget #{name} is not in the document")
        end

        def each_value(value, &block)
          block.call(value)
          case value
          when Hash then value.each_value { each_value(_1, &block) }
          when Array then value.each { each_value(_1, &block) }
          end
        end

        def named?(value, name) = widget?(value) && value['Name'] == name

        def widget?(value)
          value.is_a?(Hash) && value.key?('Name') && value['$Type'].to_s.match?(/\A(?:Forms|CustomWidgets)\$/)
        end

        def unsupported!(reason) = raise(UnsupportedEdit, "#{@page}: #{reason}")
      end
    end
    # rubocop:enable Metrics
  end
end
