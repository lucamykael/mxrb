# frozen_string_literal: true

require 'spec_helper'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::RubyApp::LegacyWidgetSourceMigration do
  def migration(embedded:, generated:, path: 'app/pages/demo_page.rb')
    described_class.new(path:, embedded_source: embedded, generated_source: generated)
  end

  it 'regenerates a page only when every legacy widget has a typed replacement' do
    embedded = <<~RUBY
      widget(:native_widget, "files", options: {"native_type" => "Forms$FileManager"})
      {"type" => "native_widget", "options" =>
        {"native_type" => "Forms$ReferenceSetSelector"}}
    RUBY
    generated = <<~RUBY
      file_manager("files", max_file_size: 5)
      reference_set_selector("members", selection: :multi)
    RUBY

    expect(migration(embedded:, generated:)).to be_regenerate
  end

  it 'upgrades image and menu native projections when every replacement is complete' do
    embedded = <<~RUBY
      native_widget "preview", type: "Forms$ImageViewer"
      native_widget "upload", type: "Forms$ImageUploader"
      native_widget "menu", type: "Forms$MenuBar"
      native_widget "tree", type: "Forms$NavigationTree"
    RUBY
    generated = <<~RUBY
      image_viewer "preview", entity: "Ui.Picture"
      image_uploader "upload"
      menu_bar "menu", menu: "Ui.MainMenu"
      navigation_tree "tree", menu: "Ui.MainMenu"
    RUBY

    expect(migration(embedded:, generated:)).to be_regenerate
  end

  it 'preserves pages containing unknown or incompletely projected native widgets' do
    unknown = 'native_widget "map", type: "Vendor$Map"'
    legacy = 'native_widget "files", type: "Forms$FileManager"'

    expect(migration(embedded: unknown, generated: 'widget :map')).not_to be_regenerate
    expect(migration(embedded: legacy, generated: 'text "files"')).not_to be_regenerate
    expect(migration(path: 'app/services/demo.rb', embedded: legacy,
                     generated: 'file_manager "files"')).not_to be_regenerate
  end

  it 'keeps the generated typed page when restoring deprecated embedded source' do
    Dir.mktmpdir do |root|
      relative = 'app/pages/demo_page.rb'
      target = File.join(root, relative)
      FileUtils.mkdir_p(File.dirname(target))
      File.write(target, 'file_manager "files"')
      embedded = 'native_widget "files", type: "Forms$FileManager"'
      exporter = Mxrb::RubyApp::Exporter.allocate
      exporter.instance_variable_set(:@output_dir, root)

      exporter.send(:restore_embedded_sources, [{
        path: relative, contents: embedded,
        sha256: Digest::SHA256.hexdigest(embedded), mode: 0o644
      }])

      expect(File.read(target)).to eq('file_manager "files"')
    end
  end
end
# rubocop:enable Metrics/BlockLength
