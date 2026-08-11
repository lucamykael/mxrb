# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'tmpdir'
require_relative '../lib/mxrb/environment'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Environment do
  def write(root, relative, content)
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  it 'loads base and profile files below process values in deterministic order' do
    Dir.mktmpdir do |root|
      write(root, '.env', "SHARED=base\nBASE=present\n")
      write(root, '.env.development', "SHARED=dot-profile\nDOT_PROFILE=yes\n")
      profile = write(
        root, 'config/environments/development.env',
        "SHARED=config-profile\nCONFIG_PROFILE=yes\n"
      )

      environment = described_class.load(
        :development, root:, process: { 'SHARED' => 'process', 'PROCESS_ONLY' => 'yes' }
      )

      expect(environment.to_h).to include(
        'SHARED' => 'process', 'BASE' => 'present', 'DOT_PROFILE' => 'yes',
        'CONFIG_PROFILE' => 'yes', 'PROCESS_ONLY' => 'yes'
      )
      expect(environment.sources.last).to eq(profile)
    end
  end

  it 'canonicalizes useful aliases and detects the profile from explicit process input' do
    Dir.mktmpdir do |root|
      write(root, 'config/environments/staging.env', "STAGE=yes\n")
      homolog = described_class.load(:homolog, root:, process: {})
      detected = described_class.load(root:, process: { 'MXRB_ENV' => 'prod' })

      expect(homolog).to have_attributes(name: 'staging', requested_name: 'homolog')
      expect(homolog.fetch('STAGE')).to eq('yes')
      expect(detected).to have_attributes(name: 'production', requested_name: 'prod')
    end
  end

  it 'parses export, comments, quotes, escapes, and values as data without expansion' do
    Dir.mktmpdir do |root|
      write(
        root, '.env', <<~ENV_FILE
          # ignored
          export SIMPLE = value # trailing comment
          HASH=kept#inside
          SINGLE='literal $SIMPLE # value'
          DOUBLE="line\\nnext\\t\\"quoted\\"" # comment
          COMMAND=$(uname)
          EMPTY=
        ENV_FILE
      )
      environment = described_class.load(root:, process: {})

      expect(environment.to_h).to include(
        'SIMPLE' => 'value', 'HASH' => 'kept#inside',
        'SINGLE' => 'literal $SIMPLE # value',
        'DOUBLE' => "line\nnext\t\"quoted\"", 'COMMAND' => '$(uname)', 'EMPTY' => ''
      )
    end
  end

  it 'rejects traversal and malformed profiles without exposing their values' do
    expect do
      described_class.load('../production', root: Dir.pwd, process: {})
    end.to raise_error(described_class::InvalidName, /invalid environment name/)

    Dir.mktmpdir do |root|
      secret = 'never-show-this-secret'
      path = write(root, '.env', "TOKEN=\"#{secret}\n")
      expect do
        described_class.load(root:, process: {})
      end.to raise_error(described_class::ParseError) { |error|
        expect(error).to have_attributes(path:, line: 1)
        expect(error.message).not_to include(secret)
      }
    end
  end

  it 'does not mutate ENV while loading and does not reveal values through inspect' do
    Dir.mktmpdir do |root|
      key = "MXRB_ENV_SPEC_#{Process.pid}"
      write(root, '.env', "#{key}=super-secret\n")
      ENV.delete(key)

      environment = described_class.load(root:, process: {})

      expect(ENV).not_to have_key(key)
      expect(environment.fetch(key)).to eq('super-secret')
      expect(environment.inspect).not_to include('super-secret')
      expect { environment.fetch('MISSING') }.to raise_error(KeyError)
      expect(environment.fetch('MISSING', 'fallback')).to eq('fallback')
      fallback = ->(_key) { 'block' }
      expect(environment.fetch('MISSING', &fallback)).to eq('block')
    ensure
      ENV.delete(key) if key
    end
  end

  it 'returns defensive hashes and applies with optional overwrite' do
    Dir.mktmpdir do |root|
      environment = described_class.load(:qa, root:, process: { 'A' => 'configured', 'B' => 'new' })
      copy = environment.to_h
      copy['A'] = 'changed'
      target = { 'A' => 'existing' }

      expect(environment.fetch('A')).to eq('configured')
      expect(environment.apply(target, overwrite: false)).to equal(target)
      expect(target).to eq('A' => 'existing', 'B' => 'new')
      environment.apply(target)
      expect(target).to eq('A' => 'configured', 'B' => 'new')
    end
  end

  it 'temporarily applies and fully restores a target after success or failure' do
    Dir.mktmpdir do |root|
      environment = described_class.load(
        :qa, root:, process: { 'PRESENT' => 'temporary', 'ADDED' => 'value' }
      )
      target = { 'PRESENT' => 'original', 'UNRELATED' => 'kept' }
      result = environment.with(target) do |current|
        expect(current).to equal(environment)
        expect(target).to include('PRESENT' => 'temporary', 'ADDED' => 'value')
        :result
      end

      expect(result).to eq(:result)
      expect(target).to eq('PRESENT' => 'original', 'UNRELATED' => 'kept')
      expect do
        environment.with(target) { raise 'failure' }
      end.to raise_error('failure')
      expect(target).to eq('PRESENT' => 'original', 'UNRELATED' => 'kept')

      environment.with(target, overwrite: false) do
        expect(target).to include('PRESENT' => 'original', 'ADDED' => 'value')
      end
      expect(target).to eq('PRESENT' => 'original', 'UNRELATED' => 'kept')
    end
  end

  it 'reports malformed keys, quotes, and encoding without exposing values' do
    Dir.mktmpdir do |root|
      write(root, '.env', "NOT A KEY=secret\n")
      expect { described_class.load(root:, process: {}) }
        .to raise_error(described_class::ParseError, /expected KEY=VALUE/)

      write(root, '.env', "SECRET='unterminated\n")
      expect { described_class.load(root:, process: {}) }
        .to raise_error(described_class::ParseError, /unterminated quoted value/)

      write(root, '.env', "SECRET='closed' trailing\n")
      expect { described_class.load(root:, process: {}) }
        .to raise_error(described_class::ParseError, /unexpected content/)

      File.binwrite(File.join(root, '.env'), "VALUE=\xFF\n".b)
      expect { described_class.load(root:, process: {}) }
        .to raise_error(described_class::ParseError, /invalid environment file/)
    end
  end

  it 'selects and inspects profiles through the CLI without printing values' do
    Dir.mktmpdir do |root|
      write(root, '.env', "BASE_SECRET=base-value\n")
      write(root, 'config/environments/qa.env', "QA_SECRET=qa-value\n")
      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby, File.expand_path('../bin/mxrb', __dir__),
        'env', root, '--environment=qa', '--json'
      )

      expect(status).to be_success
      expect(stderr).to be_empty
      payload = JSON.parse(stdout)
      expect(payload).to include('environment' => 'qa')
      expect(payload.fetch('keys')).to include('BASE_SECRET', 'QA_SECRET')
      expect(stdout).not_to include('base-value', 'qa-value')
    end
  end
end
# rubocop:enable Metrics/BlockLength
