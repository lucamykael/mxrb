# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::RubyApp::PageEdits do
  def define_project(source)
    Mxrb.define(source) do
      mendix_version '11.12.1'
      self.module(:App) do
        page(:Home) do
          title 'Welcome'
          text 'message', caption: 'Original', class_name: 'plain'
          container('box') { text 'inner', caption: 'Inside' }
        end
      end
    end
  end

  def export_project(directory)
    source = File.join(directory, 'Shop.mpr')
    define_project(source)
    app = File.join(directory, 'ruby')
    Mxrb::Exporter.new(source, app, mode: :ruby).export!
    [source, app, File.join(app, 'app', 'pages', 'app', 'home_page.rb')]
  end

  def compile_after(directory, page)
    original = File.read(page)
    source, app = yield(original)
    built = File.join(directory, 'built', File.basename(source))
    FileUtils.rm_rf(File.dirname(built))
    Mxrb::RubyApp.compile(app, built)
    expect(Mxrb.validate(built)).to be_valid
    Mxrb.compare(source, built).differences.map(&:to_s)
  ensure
    File.write(page, original)
  end

  def differences_after(directory, &edit)
    source, app, page = export_project(directory)
    compile_after(directory, page) do |original|
      File.write(page, edit.call(original))
      [source, app]
    end
  end

  around do |example|
    Dir.mktmpdir do |directory|
      @directory = directory
      example.run
    end
  end

  describe 'compiling an exported project' do
    it 'keeps a baseline for each page and leaves unedited documents alone' do
      source, app, = export_project(@directory)
      built = File.join(@directory, 'built', 'Shop.mpr')
      manifest = Mxrb::RubyApp::Manifest.load(app)
      id = manifest.modules.flat_map { _1.fetch('pages') }.first.fetch('id')

      Mxrb::RubyApp.compile(app, built)

      expect(described_class.baseline?(app, id)).to be(true)
      expect(Mxrb.compare(source, built)).to be_identical
    end

    it 'ignores a change to the source that does not change the page' do
      expect(differences_after(@directory) { "#{_1}\n# reviewed\n" }).to be_empty
    end

    it 'applies a title' do
      differences = differences_after(@directory) { _1.sub('title: "Welcome"', 'title: "Hello"') }

      expect(differences).to contain_exactly(a_string_including('pages.Home.title', '"Welcome"', '"Hello"'))
    end

    it 'applies a caption, including one inside a container' do
      differences = differences_after(@directory) { _1.sub('caption: "Inside"', 'caption: "Edited"') }

      expect(differences).to contain_exactly(a_string_including('inner', '"Inside"', '"Edited"'))
    end

    it 'applies a widget class' do
      differences = differences_after(@directory) { _1.sub('class_name: "plain"', 'class_name: "fancy"') }

      expect(differences).to contain_exactly(a_string_including('message', '"plain"', '"fancy"'))
    end

    it 'removes a widget, even the last one of its parent' do
      differences = differences_after(@directory) { _1.sub(/^\s*text "inner", caption: "Inside"\n/, '') }

      expect(differences).not_to be_empty
      expect(differences.join).to include('inner')
    end

    it 'fails rather than losing an edit it cannot apply' do
      expect do
        differences_after(@directory) { _1.sub(/^(\s*)text "message".*$/, "\\0\n\\1text \"added\", caption: \"New\"") }
      end.to raise_error(described_class::UnsupportedEdit, /App\.Home: .*adds added/)
    end

    it 'fails when the page declaration is deleted' do
      source, app, page = export_project(@directory)
      FileUtils.rm(page)

      expect { Mxrb::RubyApp.compile(app, File.join(@directory, 'built', File.basename(source))) }
        .to raise_error(described_class::UnsupportedEdit, /App\.Home: the page declaration was removed or renamed/)
    end

    it 'reads a page that moved to another file' do
      source, app, page = export_project(@directory)
      moved = File.join(File.dirname(page), 'renamed_home_page.rb')
      File.write(moved, File.read(page).sub('title: "Welcome"', 'title: "Moved"'))
      FileUtils.rm(page)
      built = File.join(@directory, 'built', File.basename(source))

      Mxrb::RubyApp.compile(app, built)

      expect(Mxrb.compare(source, built).differences.map(&:to_s))
        .to contain_exactly(a_string_including('pages.Home.title', '"Moved"'))
    end

    it 'skips edits when the project asks to preserve its native pages' do
      source, app, page = export_project(@directory)
      FileUtils.touch(File.join(app, '.mxrb', 'preserve_native_pages'))
      File.write(page, File.read(page).sub('title: "Welcome"', 'title: "Hello"'))
      built = File.join(@directory, 'built', File.basename(source))

      Mxrb::RubyApp.compile(app, built)

      expect(Mxrb.compare(source, built)).to be_identical
    end

    it 'skips a page without a baseline, as in a project exported before this synchronization' do
      source, app, page = export_project(@directory)
      FileUtils.rm_rf(File.join(app, described_class::BASELINE_DIRECTORY))
      File.write(page, File.read(page).sub('title: "Welcome"', 'title: "Hello"'))
      built = File.join(@directory, 'built', File.basename(source))

      Mxrb::RubyApp.compile(app, built)

      expect(Mxrb.compare(source, built)).to be_identical
    end

    it 'leaves a page that declares native to the native synchronization' do
      differences = differences_after(@directory) do |source|
        source.sub(/^    configure\(.*\z/m, "    native do\n      title \"Native\"\n    end\n  end\nend\n")
      end

      expect(differences.join).to include('"Native"')
    end

    it 'keeps an applied edit through another export' do
      source, app, page = export_project(@directory)
      File.write(page, File.read(page).sub('title: "Welcome"', 'title: "Hello"'))
      built = File.join(@directory, 'built', File.basename(source))
      Mxrb::RubyApp.compile(app, built)
      again = File.join(@directory, 'again')
      Mxrb::Exporter.new(built, again, mode: :ruby).export!
      rebuilt = File.join(@directory, 'rebuilt', File.basename(source))

      Mxrb::RubyApp.compile(again, rebuilt)

      expect(Mxrb.compare(built, rebuilt)).to be_identical
      expect(File.read(File.join(again, 'app', 'pages', 'app', 'home_page.rb'))).to include('title: "Hello"')
    end
  end

  describe '.comparable' do
    it 'reads a value as JSON and drops element identities at any depth' do
      value = { '$ID': 'a', name: :text, rows: [{ '$ID' => 'b', 'count' => 1 }, nil] }

      expect(described_class.comparable(value)).to eq('name' => 'text', 'rows' => [{ 'count' => 1 }, nil])
    end
  end

  describe 'the portability report' do
    it 'reports an exported page as native' do
      _source, app, = export_project(@directory)

      entry = Mxrb::RubyApp::PortabilityReport.new(app).entries.find { _1.name == 'App.Home' }

      expect(entry.status).to eq('native')
      expect(entry.reason).to include('applied to its Mendix document')
    end
  end

  describe described_class::Comparison do
    def snapshot(widgets = [], **fields)
      { title: 'T', appearance_class: '', appearance_style: '', allowed_module_roles: [], data_source: nil,
        widgets: }.merge(fields)
    end

    def changes(before, after) = described_class.new('App.Home', before, after).changes
    def widget(name, **fields) = { 'type' => 'text', 'name' => name }.merge(fields.transform_keys(&:to_s))

    it 'lists page appearance' do
      expect(changes(snapshot, snapshot(appearance_class: 'a', appearance_style: 'b')))
        .to eq([[:page_appearance, 'Class', 'a'], [:page_appearance, 'Style', 'b']])
    end

    it 'rejects a change of roles or data source' do
      expect { changes(snapshot, snapshot(allowed_module_roles: ['App.User'])) }
        .to raise_error(Mxrb::RubyApp::PageEdits::UnsupportedEdit, /allowed_module_roles/)
      expect { changes(snapshot, snapshot(data_source: { 'x' => 1 })) }
        .to raise_error(Mxrb::RubyApp::PageEdits::UnsupportedEdit, /data_source/)
    end

    it 'reads a class and a style added to a widget without options' do
      expect(changes(snapshot([widget('a')]), snapshot([widget('a', options: { 'class' => 'c', 'style' => 's' })])))
        .to eq([[:appearance, 'a', 'Class', 'c'], [:appearance, 'a', 'Style', 's']])
      expect(changes(snapshot([widget('a', options: { 'class' => 'c' })]), snapshot([widget('a')])))
        .to eq([[:appearance, 'a', 'Class', '']])
    end

    it 'lists a caption once, however many places repeat it' do
      before = widget('a', caption: 'x', options: { 'caption' => 'x' })
      after = widget('a', caption: 'y', options: { 'caption' => 'y' })

      expect(changes(snapshot([before]), snapshot([after]))).to eq([[:caption, 'a', 'x', 'y']])
    end

    it 'lists a new order and removals among named widgets' do
      list = [widget('a'), widget('b'), widget('c')]

      expect(changes(snapshot(list), snapshot(list.reverse))).to eq([[:order, %w[c b a]]])
      expect(changes(snapshot(list), snapshot([list[0], list[2]]))).to eq([[:remove, 'b']])
    end

    it 'reads a list that appears or disappears' do
      child = widget('b')

      expect(changes(snapshot([widget('a', children: [child])]), snapshot([widget('a')])))
        .to eq([[:remove, 'b']])
      expect { changes(snapshot([widget('a')]), snapshot([widget('a', children: [child])])) }
        .to raise_error(Mxrb::RubyApp::PageEdits::UnsupportedEdit, /adds b/)
    end

    it 'follows widgets nested in plain structures' do
      before = widget('g', options: { 'rows' => [{ 'cells' => [widget('t', caption: 'x')] }] })
      after = widget('g', options: { 'rows' => [{ 'cells' => [widget('t', caption: 'y')] }] })

      expect(changes(snapshot([before]), snapshot([after]))).to eq([[:caption, 't', 'x', 'y']])
    end

    it 'reads a widget in a list it cannot match by name' do
      expect(changes(snapshot([widget('', caption: 'x')]), snapshot([widget('', caption: 'y')])))
        .to eq([[:caption, '', 'x', 'y']])
    end

    it 'rejects what it cannot read as an edit' do
      {
        'a changed type' => [[widget('a')], [widget('a').merge('type' => 'button')], /widget type or name/],
        'an unnamed list resized' => [[widget('')], [widget(''), widget('')], /cannot be applied/],
        'duplicate names resized' => [[widget('a'), widget('a')], [widget('a')], /cannot be applied/],
        'a plain list resized' => [[widget('a', options: { 'x' => [1] })], [widget('a', options: { 'x' => [1, 2] })],
                                   /cannot be applied/],
        'another option' => [[widget('a', options: { 'x' => 1 })], [widget('a', options: { 'x' => 2 })],
                             /options\.x changed from 1 to 2/],
        'a value outside a widget' => [[{ 'plain' => 1 }], [{ 'plain' => 2 }], /widgets\[0\]\.plain/]
      }.each_value do |before, after, message|
        expect { changes(snapshot(before), snapshot(after)) }
          .to raise_error(Mxrb::RubyApp::PageEdits::UnsupportedEdit, message)
      end
    end
  end

  describe described_class::Document do
    def text(*values, type: 'Texts$Text')
      { '$Type' => type, 'Items' => [3] + values.map { { '$Type' => 'Texts$Translation', 'Text' => _1 } } }
    end

    def read(text) = text.fetch('Items').grep(Hash).map { _1.fetch('Text') }

    def document(widgets = [], **fields)
      { '$Type' => 'Forms$Page', 'Name' => 'Home', 'Title' => text('T', 'Titel'),
        'Appearance' => { 'Class' => '', 'Style' => '' }, 'Widgets' => [3] + widgets }
        .merge(fields.transform_keys(&:to_s))
    end

    def element(name, **fields)
      { '$Type' => 'Forms$Thing', 'Name' => name }.merge(fields.transform_keys(&:to_s))
    end

    def apply(raw, *changes) = described_class.new('App.Home', raw).apply(changes).then { raw }
    def rejected = raise_error(Mxrb::RubyApp::PageEdits::UnsupportedEdit)

    it 'changes one language of the title' do
      expect(read(apply(document, [:title, 'T', 'New']).fetch('Title'))).to eq(%w[New Titel])
    end

    it 'rejects a title the document does not hold' do
      expect { apply(document, [:title, 'Other', 'New']) }.to rejected
    end

    it 'sets appearance in the Appearance of the page and of a widget' do
      raw = document([element('a', Appearance: { 'Class' => '' })])

      apply(raw, [:page_appearance, 'Style', 's'], [:appearance, 'a', 'Class', 'c'])

      expect(raw.dig('Appearance', 'Style')).to eq('s')
      expect(raw.fetch('Widgets').last.dig('Appearance', 'Class')).to eq('c')
    end

    it 'sets appearance on the widget itself when the model has no Appearance' do
      raw = document([element('a', Class: '')])

      apply(raw, [:appearance, 'a', 'Class', 'c'])

      expect(raw.fetch('Widgets').last.fetch('Class')).to eq('c')
    end

    it 'rejects appearance a widget does not have' do
      expect { apply(document([element('a')]), [:appearance, 'a', 'Class', 'c']) }.to rejected
    end

    it 'changes the caption of a widget and not of those inside it or its fallback' do
      inner = element('b', Caption: text('Same'))
      outer = element('a', Content: { 'Template' => text('Same'), 'Fallback' => text('Same') }, Items: [3, inner])

      apply(document([outer]), [:caption, 'a', 'Same', 'New'])

      expect(read(outer.dig('Content', 'Template'))).to eq(['New'])
      expect(read(outer.dig('Content', 'Fallback'))).to eq(['Same'])
      expect(read(inner.fetch('Caption'))).to eq(['Same'])
    end

    it 'skips a widget held directly by a field' do
      nested = element('b', Caption: text('Same'))
      outer = element('a', Caption: text('Same'), Header: nested)

      apply(document([outer]), [:caption, 'a', 'Same', 'New'])

      expect(read(nested.fetch('Caption'))).to eq(['Same'])
    end

    it 'changes every caption field that repeats the caption, and not other texts' do
      raw = element('a', Caption: text('Save'), CaptionTemplate: { 'Template' => text('Save') }, Tooltip: text('Save'))

      apply(document([raw]), [:caption, 'a', 'Save', 'New'])

      expect(read(raw.fetch('Caption'))).to eq(['New'])
      expect(read(raw.dig('CaptionTemplate', 'Template'))).to eq(['New'])
      expect(read(raw.fetch('Tooltip'))).to eq(['Save'])
    end

    it 'rejects a caption it cannot place' do
      expect { apply(document([element('a')]), [:caption, 'a', 'x', 'y']) }.to rejected
      ambiguous = element('a', One: text('x'), Two: text('x'))
      expect { apply(document([ambiguous]), [:caption, 'a', 'x', 'y']) }.to rejected
    end

    it 'rejects a widget it cannot find or tell apart' do
      expect { apply(document, [:appearance, 'a', 'Class', 'c']) }.to rejected
      expect { apply(document, [:remove, 'a']) }.to rejected
      expect { apply(document([element('a'), element('a')]), [:appearance, 'a', 'Class', 'c']) }.to rejected
    end

    it 'removes and orders widgets, keeping the list marker and other entries in place' do
      raw = document([element('a'), { '$Type' => 'Forms$Other' }, element('b'), element('c')])

      apply(raw, [:remove, 'c'], [:order, %w[b a]])

      expect(raw.fetch('Widgets').map { _1.is_a?(Hash) ? _1.fetch('Name', '-') : _1 }).to eq([3, 'b', '-', 'a'])
    end

    it 'rejects an order across parents' do
      raw = document([element('a', Widgets: [3, element('b')])])

      expect { apply(raw, [:order, %w[a b]]) }.to rejected
    end
  end
end
# rubocop:enable Metrics/BlockLength
