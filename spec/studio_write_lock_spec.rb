# frozen_string_literal: true

require 'spec_helper'
require 'mxrb/studio/write_lock'
require 'tmpdir'

# rubocop:disable Metrics
RSpec.describe Mxrb::Studio::WriteLock do
  around do |example|
    Dir.mktmpdir('mxrb-write-lock-') do |directory|
      @directory = directory
      original = ENV.fetch('XDG_STATE_HOME', nil)
      ENV['XDG_STATE_HOME'] = File.join(directory, 'state')
      example.run
    ensure
      ENV['XDG_STATE_HOME'] = original
    end
  end

  let(:target) { File.join(@directory, 'App.mpr') }

  def hold_elsewhere
    FileUtils.mkdir_p(described_class.directory)
    file = File.open(described_class.path_for(target), File::RDWR | File::CREAT, 0o600)
    file.flock(File::LOCK_EX)
    file
  end

  it 'names the lock file by the SHA-256 of the expanded target under the state directory' do
    lock = described_class.new(target)
    expect(lock.target).to eq(target)
    expect(lock.path).to eq(File.join(@directory, 'state', 'mxrb', 'studio', 'locks',
                                      Digest::SHA256.hexdigest(target)))
  end

  it 'is reentrant for the holding thread and releases on exit' do
    result = described_class.synchronize(target) do
      described_class.synchronize(target, timeout: 0) { :nested }
    end
    expect(result).to eq(:nested)
    expect(Thread.current[described_class::HELD]).to eq([])
    lock = described_class.new(target)
    file = lock.acquire
    expect(file).not_to be_closed
    lock.release(file)
    expect(file).to be_closed
  end

  it 'raises Busy after the timeout while another open file holds the lock' do
    other = hold_elsewhere
    expect { described_class.synchronize(target, timeout: 0.12) { :never } }
      .to raise_error(Mxrb::Studio::Busy, /App\.mpr is being written/)
    expect(Thread.current[described_class::HELD]).to eq([])
  ensure
    other&.close
  end

  it 'waits for another holder that releases before the timeout' do
    other = hold_elsewhere
    releaser = Thread.new do
      sleep 0.1
      other.flock(File::LOCK_UN)
    end
    expect(described_class.synchronize(target, timeout: 5) { :acquired }).to eq(:acquired)
    releaser.join
  ensure
    other&.close
  end

  it 'excludes a writer in another process' do
    reader, writer = IO.pipe
    pid = fork do
      reader.close
      described_class.synchronize(target) do
        writer.puts('locked')
        sleep 0.5
      end
      exit!(0)
    end
    writer.close
    expect(reader.gets).to eq("locked\n")
    expect { described_class.new(target).acquire(0) }.to raise_error(Mxrb::Studio::Busy)
    Process.wait(pid)
    expect(described_class.synchronize(target, timeout: 0) { :free }).to eq(:free)
  ensure
    reader&.close
  end
end
# rubocop:enable Metrics
