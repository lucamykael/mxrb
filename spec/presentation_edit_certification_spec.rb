# frozen_string_literal: true

require 'spec_helper'
load File.expand_path('../script/certify_presentation_edits', __dir__)

RSpec.describe PresentationEditCertification do # rubocop:disable Metrics/BlockLength
  def fixture(root) # rubocop:disable Metrics/MethodLength
    fixtures = File.join(root, 'fixtures')
    FileUtils.mkdir_p(fixtures)
    source = File.join(fixtures, 'Shop.mpr')
    Mxrb.define(source) do
      mendix_version '11.12.1'
      self.module(:Shop) do
        page(:Home) do
          title 'Original title'
          text 'message', caption: 'Original text'
        end
      end
    end
    edit = { 'file' => 'app/pages/shop/home_page.rb', 'from' => 'title: "Original title"',
             'to' => 'title: "Edited title"', 'unit' => 'Shop.Home', 'kind' => 'page',
             'field' => ['Title', 'Items', 1, 'Text'], 'value' => 'Edited title' }
    test_case = { 'label' => 'shop', 'mpr' => 'Shop.mpr', 'fixture' => PipelineBenchmark.fixture_identity(source),
                  'edits' => [edit] }
    [fixtures, source, { 'schema_version' => 1, 'cases' => [test_case] }]
  end

  it 'certifies real Ruby edits without the runtime MPR and preserves the source bytes' do
    Dir.mktmpdir do |root|
      fixtures, source, plan = fixture(root)
      FileUtils.mkdir_p(File.join(fixtures, 'theme-cache', 'web'))
      File.write(File.join(fixtures, 'theme-cache', 'web', 'theme.compiled.css'), 'body { color: blue; }')
      before = File.binread(source)
      output = File.join(root, 'evidence')
      report = described_class.run(plan, fixtures, output)
      expect(report).to include(passed: true)
      expect(report[:cases].first).to include(rebuilt_from: 'mendix_sidecar', native_oracle: 'not_run')
      expect(report[:cases].first[:differences]).not_to be_empty
      expect(File.binread(source)).to eq(before)
      manifest = Mxrb::RubyApp::Manifest.load(File.join(output, 'shop', 'ruby'))
      expect(File).not_to exist(manifest.absolute_path('runtime_mpr'))
      expect(JSON.parse(File.read(File.join(output, 'cases.json'))).first)
        .to include('source' => 'shop/source', 'rebuilt' => 'shop/rebuilt')
    end
  end

  it 'fails on an unexpected edit instead of treating any changed model as a success' do
    Dir.mktmpdir do |root|
      fixtures, _source, plan = fixture(root)
      plan['cases'].first['edits'].first['to'] = 'title: "Different title"'
      report = described_class.run(plan, fixtures, File.join(root, 'evidence'))
      expect(report).to include(passed: false)
      expect(report[:cases].first[:error]).to include('Edited title', 'Different title')
    end
  end

  it 'rejects changed fixtures before exporting and keeps failed cases out of oracle inputs' do
    Dir.mktmpdir do |root|
      fixtures, source, plan = fixture(root)
      File.open(source, 'ab') { _1.write('drift') }
      output = File.join(root, 'evidence')
      report = described_class.run(plan, fixtures, output)
      expect(report[:cases].first[:error]).to include('checksum mismatch')
      expect(JSON.parse(File.read(File.join(output, 'cases.json')))).to eq([])
      expect(File).not_to exist(File.join(output, 'shop', 'ruby'))
    end
  end

  it 'rejects paths leaving the source workspace, including symlinks' do
    Dir.mktmpdir do |root|
      outside = File.join(root, 'outside.rb')
      File.write(outside, 'original')
      inside = File.join(root, 'inside')
      FileUtils.mkdir_p(inside)
      File.symlink(outside, File.join(inside, 'link.rb'))
      ['../outside.rb', 'link.rb'].each do |file|
        expect { described_class.edit_ruby(inside, [{ 'file' => file, 'from' => 'original', 'to' => 'changed' }]) }
          .to raise_error(ArgumentError, /outside workspace/)
      end
      expect(File.read(outside)).to eq('original')
    end
  end

  it 'refuses to create its output inside a project that will be copied' do
    Dir.mktmpdir do |root|
      fixtures, _source, plan = fixture(root)
      output = File.join(fixtures, 'recursive')
      expect { described_class.run(plan, fixtures, output) }.to raise_error(ArgumentError, /outside the source/)
      expect(File).not_to exist(output)
    end
  end

  it 'rejects ambiguous replacements and widget identities' do
    Dir.mktmpdir do |root|
      File.write(File.join(root, 'app.rb'), 'same same')
      expect { described_class.edit_ruby(root, [{ 'file' => 'app.rb', 'from' => 'same', 'to' => 'changed' }]) }
        .to raise_error(ArgumentError, /exactly once/)
    end
    widget = { '$Type' => 'Forms$Text', 'Name' => 'same' }
    expect { described_class.field_owner({ 'Widgets' => [widget, widget] }, { 'widget' => 'same' }) }
      .to raise_error(ArgumentError, /ambiguous/)
  end
end
