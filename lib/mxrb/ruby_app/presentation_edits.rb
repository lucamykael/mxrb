# frozen_string_literal: true

module Mxrb
  module RubyApp
    # rubocop:disable Metrics
    # Carries edits of exported layouts and snippets to their native documents, as
    # PageEdits does for pages. A file still equal to its baseline is not evaluated.
    # Menus, images and icons have no native counterpart here, so editing one raises.
    class PresentationEdits
      BASELINE_DIRECTORY = File.join('.mxrb', 'presentation_baselines')
      SOURCE_DIRECTORY = File.join('app', 'presentation')
      DOCUMENT_KINDS = %w[layout snippet].freeze
      # The exporter wraps a layout in this container to show the layout's own appearance.
      LAYOUT_APPEARANCE = 'LayoutAppearance'

      def self.write_baselines(root)
        source = File.join(root, SOURCE_DIRECTORY)
        return unless File.directory?(source)

        FileUtils.mkdir_p(File.dirname(File.join(root, BASELINE_DIRECTORY)))
        FileUtils.cp_r(source, File.join(root, BASELINE_DIRECTORY))
      end

      def initialize(project, manifest)
        @project = project
        @manifest = manifest
        @root = manifest.root
      end

      def apply!
        return unless File.directory?(File.join(@root, BASELINE_DIRECTORY)) && edited?

        before = baseline_resources
        after = Registry.all(:presentation)
        documents = @project.modules.flat_map do |mod|
          mod.presentation_documents.map { ["#{mod.name}.#{_1.fetch(:name)}", _1] }
        end.to_h
        changed = (before.keys | after.keys).reject { before[_1] == after[_1] }
        return if changed.empty?

        @project.mpr.transaction do
          changed.each { apply_resource(_1, before[_1], after[_1], documents[_1]) }
        end
        @project.refresh!
      end

      private

      def edited?
        sources(BASELINE_DIRECTORY) != sources(SOURCE_DIRECTORY)
      end

      def sources(directory)
        base = File.join(@root, directory)
        Dir.glob('**/*.rb', base:).sort.to_h { [_1, File.binread(File.join(base, _1))] }
      end

      def baseline_resources
        registered = Registry.snapshot
        Registry.reset!
        Dir.glob('**/*.rb', base: File.join(@root, BASELINE_DIRECTORY)).sort.each do |path|
          PageEdits.evaluate(@manifest, File.join(@root, BASELINE_DIRECTORY, path))
        end
        Registry.all(:presentation)
      ensure
        Registry.restore!(registered)
      end

      def apply_resource(name, before, after, document)
        unsupported!(name, 'adding or removing a presentation declaration is not supported yet') unless before && after
        kind = after.fetch(:kind)
        unless before.fetch(:kind) == kind && DOCUMENT_KINDS.include?(kind)
          unsupported!(name, "editing a #{kind} is not supported yet")
        end
        unless PageEdits.comparable(before.except(:widgets)) == PageEdits.comparable(after.except(:widgets))
          unsupported!(name, 'changing parameters or variables is not supported yet')
        end

        changes = PageEdits::Comparison.new(name, snapshot(before), snapshot(after)).changes
        return if changes.empty?

        unsupported!(name, 'the document is not in the model') unless document

        raw = document.fetch(:doc)
        PageEdits::Document.new(name, raw).apply(changes.map { layout_appearance(_1) })
        @project.mpr.update_unit(document.fetch(:id), raw)
      end

      def layout_appearance(change)
        kind, widget, key, value = change
        kind == :appearance && widget == LAYOUT_APPEARANCE ? [:page_appearance, key, value] : change
      end

      def snapshot(resource)
        { title: '', appearance_class: '', appearance_style: '', allowed_module_roles: [], data_source: nil,
          widgets: PageEdits.comparable(resource.fetch(:widgets)) }
      end

      def unsupported!(name, reason) = raise(PageEdits::UnsupportedEdit, "#{name}: #{reason}")
    end
    # rubocop:enable Metrics
  end
end
