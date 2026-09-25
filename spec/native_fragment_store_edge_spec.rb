# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

RSpec.describe Mxrb::NativeFragmentStore do # rubocop:disable Metrics/BlockLength
  it 'validates input, digests, declarations, overrides, and configured access' do # rubocop:disable Metrics/BlockLength
    Dir.mktmpdir('mxrb-fragments-') do |directory|
      store = described_class.new(directory)
      expect { store.put([]) }.to raise_error(ArgumentError, /must be a Hash/)
      expect { store.fetch('invalid') }.to raise_error(Mxrb::ValidationError, /invalid.*digest/)
      missing = '0' * 64
      expect { store.fetch(missing) }.to raise_error(Mxrb::ValidationError, /does not exist/)

      document = {
        '$Type' => 'Root', 'Endpoint' => 'https://example.invalid',
        'Nested' => { '$Type' => 'Child', 'Name' => 'before' }
      }
      digest = store.put(document)
      expect(store.put(document)).to eq(digest)
      expect(store.fetch(digest, types: %w[Root Child], hints: ['https://example.invalid'],
                                 overrides: { 'Endpoint' => nil }))
        .to include('Endpoint' => nil)
      expect { store.fetch(digest, types: ['Missing']) }
        .to raise_error(Mxrb::ValidationError, /missing declared type/)
      expect { store.fetch(digest, hints: ['private.example']) }
        .to raise_error(Mxrb::ValidationError, /missing declared hint/)
      expect { store.fetch(digest, overrides: []) }
        .to raise_error(Mxrb::ValidationError, /overrides must be a Hash/)
      expect { store.fetch(digest, overrides: { 'Nested' => 'invalid' }) }
        .to raise_error(Mxrb::ValidationError, /invalid native fragment override/)

      path = File.join(directory, "#{digest}.bson")
      File.binwrite(path, 'tampered')
      expect { store.fetch(digest) }.to raise_error(Mxrb::ValidationError, /digest mismatch/)
    end

    access = Object.new.extend(Mxrb::NativeFragmentAccess)
    expect { access.native_fragment('0' * 64) }
      .to raise_error(Mxrb::ValidationError, /store is not configured/)
  end

  it 'restores the prior thread-local store after a failed evaluation' do
    previous = described_class.new('/tmp/previous-fragments')
    current = described_class.new('/tmp/current-fragments')
    Thread.current[described_class::THREAD_KEY] = previous
    expect { described_class.with(current) { raise 'failure' } }.to raise_error('failure')
    expect(described_class.current).to equal(previous)
  ensure
    Thread.current[described_class::THREAD_KEY] = nil
  end
end
