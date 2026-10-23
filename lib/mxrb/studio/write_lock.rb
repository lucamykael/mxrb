# frozen_string_literal: true

require 'digest'
require 'fileutils'

module Mxrb
  module Studio
    class Busy < StandardError; end

    # Coordinates writers of the same model or workspace across processes. The
    # lock file lives under $XDG_STATE_HOME/mxrb/studio/locks and is named by the
    # SHA-256 of the canonical target path, so any cooperating writer (the IDE
    # before it saves, MXRB before it patches units) can take the same flock.
    # Nested acquisitions by the thread that already holds a lock are reentrant.
    class WriteLock
      HELD = :mxrb_studio_write_locks
      POLL_INTERVAL = 0.05
      DEFAULT_TIMEOUT = 30

      def self.directory
        state = ENV.fetch('XDG_STATE_HOME', File.join(Dir.home, '.local', 'state'))
        File.join(state, 'mxrb', 'studio', 'locks')
      end

      def self.path_for(target)
        File.join(directory, Digest::SHA256.hexdigest(File.expand_path(target)))
      end

      def self.synchronize(target, timeout: DEFAULT_TIMEOUT, &)
        new(target).synchronize(timeout:, &)
      end

      attr_reader :target, :path

      def initialize(target)
        @target = File.expand_path(target)
        @path = self.class.path_for(@target)
      end

      def synchronize(timeout: DEFAULT_TIMEOUT)
        held = (Thread.current[HELD] ||= [])
        return yield if held.include?(path)

        file = acquire(timeout)
        held << path
        begin
          yield
        ensure
          held.delete(path)
          release(file)
        end
      end

      # Returns an open, locked file; the caller releases it with #release.
      def acquire(timeout = nil)
        FileUtils.mkdir_p(self.class.directory, mode: 0o700)
        file = File.open(path, File::RDWR | File::CREAT, 0o600)
        wait_for(file, timeout)
        file
      rescue Busy
        file&.close
        raise
      end

      def release(file)
        file.flock(File::LOCK_UN)
      ensure
        file.close
      end

      private

      def wait_for(file, timeout)
        return file.flock(File::LOCK_EX) if timeout.nil?

        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        until file.flock(File::LOCK_EX | File::LOCK_NB)
          if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
            raise Busy, "#{File.basename(target)} is being written by another process; retry after it saves"
          end

          sleep POLL_INTERVAL
        end
      end
    end
  end
end
