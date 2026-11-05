# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::RubyApp::PresentationEdits do
  def export_project
    source = File.join(@directory, 'Shop.mpr')
    Mxrb.define(source) do
      mendix_version '11.12.1'
      self.module(:App) { page(:Home) { text 'message', caption: 'Original' } }
    end
    app = File.join(@directory, 'ruby')
    Mxrb::Exporter.new(source, app, mode: :ruby).export!
    [source, app, File.join(app, 'app', 'presentation', 'app.rb')]
  end

  # The raw documents, because Mxrb.compare leaves out what regeneration may vary.
  def documents(path)
    Mxrb.open(path) do |project|
      project.modules.flat_map(&:presentation_documents).to_h { [_1.fetch(:name), _1.fetch(:doc)] }
    end
  end

  def compile(source, app)
    built = File.join(@directory, 'built', File.basename(source))
    FileUtils.rm_rf(File.dirname(built))
    Mxrb::RubyApp.compile(app, built)
    expect(Mxrb.validate(built)).to be_valid
    built
  end

  def edit_and_compile(&edit)
    source, app, file = export_project
    File.write(file, edit.call(File.read(file)))
    [documents(source).fetch('ApplicationLayout'), documents(compile(source, app)).fetch('ApplicationLayout')]
  end

  def expect_unchanged(source, built)
    expect(documents(built)).to eq(documents(source))
  end

  # A declaration in both the baseline and the source, so only the given edit differs.
  def declare_in_both(app, file, declaration)
    baseline = File.join(app, described_class::BASELINE_DIRECTORY, 'app.rb')
    File.write(baseline, "#{File.read(baseline)}\n#{declaration}\n")
    File.write(file, "#{File.read(file)}\n#{declaration}\n")
  end

  around do |example|
    Dir.mktmpdir do |directory|
      @directory = directory
      example.run
    end
  end

  it 'leaves unedited documents alone' do
    source, app, = export_project

    expect_unchanged(source, compile(source, app))
  end

  it 'ignores a comment' do
    before, after = edit_and_compile { "#{_1}\n# reviewed\n" }

    expect(after).to eq(before)
  end

  it 'applies a caption in a layout' do
    before, after = edit_and_compile { _1.sub('caption: "App"', 'caption: "Shop"') }

    expect(after).not_to eq(before)
    expect(JSON.generate(after)).to include('"Text":"Shop"')
    expect(JSON.generate(after).sub('"Text":"Shop"', '"Text":"App"')).to eq(JSON.generate(before))
  end

  it 'applies the class of a widget in a layout' do
    before, after = edit_and_compile { _1.sub('class_name: "mxrb-topbar"', 'class_name: "bar"') }

    expect(JSON.generate(after)).to eq(JSON.generate(before).sub('"Class":"mxrb-topbar"', '"Class":"bar"'))
  end

  it 'applies the class of the layout itself to its document' do
    _before, after = edit_and_compile { _1.sub('class_name: "mxrb-application-shell"', 'class_name: "shell"') }

    expect(after.dig('Appearance', 'Class')).to eq('shell')
  end

  it 'fails on an edit a layout document cannot take' do
    expect { edit_and_compile { _1.sub('size: 72', 'size: 80') } }
      .to raise_error(Mxrb::RubyApp::PageEdits::UnsupportedEdit, /App\.ApplicationLayout: .*size/)
  end

  it 'fails when a declaration is added or removed' do
    expect { edit_and_compile { %(#{_1}\nMxrb::RubyApp::Presentation.layout "App.Extra" do\nend\n) } }
      .to raise_error(Mxrb::RubyApp::PageEdits::UnsupportedEdit, /App\.Extra: adding or removing/)
  end

  it 'fails on a kind it does not apply' do
    source, app, file = export_project
    declare_in_both(app, file, 'Mxrb::RubyApp::Presentation.menu("App.Menu") { item "One" }')
    File.write(file, File.read(file).sub('item "One"', 'item "Two"'))

    expect { compile(source, app) }
      .to raise_error(Mxrb::RubyApp::PageEdits::UnsupportedEdit, /App\.Menu: editing a menu/)
  end

  it 'fails when a declaration changes kind' do
    source, app, file = export_project
    declare_in_both(app, file, 'Mxrb::RubyApp::Presentation.snippet("App.Thing") { text "t", caption: "x" }')
    File.write(file, File.read(file).sub('Presentation.snippet("App.Thing")', 'Presentation.layout("App.Thing")'))

    expect { compile(source, app) }
      .to raise_error(Mxrb::RubyApp::PageEdits::UnsupportedEdit, /App\.Thing: editing a layout/)
  end

  it 'fails when a snippet changes its parameters' do
    source, app, file = export_project
    declare_in_both(app, file, 'Mxrb::RubyApp::Presentation.snippet("App.Thing", parameters: []) { text "t" }')
    File.write(file, File.read(file).sub('parameters: []', 'parameters: [{ name: "Order" }]'))

    expect { compile(source, app) }
      .to raise_error(Mxrb::RubyApp::PageEdits::UnsupportedEdit, /App\.Thing: changing parameters/)
  end

  it 'fails when the document is not in the model' do
    source, app, file = export_project
    declare_in_both(app, file, 'Mxrb::RubyApp::Presentation.snippet("App.Ghost") { text "t", caption: "x" }')
    File.write(file, File.read(file).sub('caption: "x"', 'caption: "y"'))

    expect { compile(source, app) }
      .to raise_error(Mxrb::RubyApp::PageEdits::UnsupportedEdit, /App\.Ghost: the document is not in the model/)
  end

  it 'does not rewrite a document whose declaration only generates new identities' do
    source, app, file = export_project
    declaration = 'Mxrb::RubyApp::Presentation.snippet("App.Ghost") ' \
                  '{ native_widget "w", type: "x", deep_structure: { "$ID" => SecureRandom.uuid } }'
    declare_in_both(app, file, declaration)
    File.write(file, "#{File.read(file)}\n# reviewed\n")

    expect_unchanged(source, compile(source, app))
  end

  it 'skips edits when the project asks to preserve its native pages' do
    source, app, file = export_project
    FileUtils.touch(File.join(app, '.mxrb', 'preserve_native_pages'))
    File.write(file, File.read(file).sub('caption: "App"', 'caption: "Shop"'))

    expect_unchanged(source, compile(source, app))
  end

  it 'skips a project exported before these baselines' do
    source, app, file = export_project
    FileUtils.rm_rf(File.join(app, described_class::BASELINE_DIRECTORY))
    File.write(file, File.read(file).sub('caption: "App"', 'caption: "Shop"'))

    expect_unchanged(source, compile(source, app))
  end

  it 'writes no baselines for a project without presentation sources' do
    described_class.write_baselines(@directory)

    expect(File.exist?(File.join(@directory, described_class::BASELINE_DIRECTORY))).to be(false)
  end

  it 'keeps an applied edit through another export' do
    source, app, file = export_project
    File.write(file, File.read(file).sub('caption: "App"', 'caption: "Shop"'))
    built = File.join(@directory, 'built', File.basename(source))
    Mxrb::RubyApp.compile(app, built)
    again = File.join(@directory, 'again')
    Mxrb::Exporter.new(built, again, mode: :ruby).export!
    rebuilt = File.join(@directory, 'rebuilt', File.basename(source))

    Mxrb::RubyApp.compile(again, rebuilt)

    expect(documents(rebuilt)).to eq(documents(built))
    expect(File.read(File.join(again, 'app', 'presentation', 'app.rb'))).to include('caption: "Shop"')
  end
end
# rubocop:enable Metrics/BlockLength
