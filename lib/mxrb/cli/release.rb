# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'net/http'
require 'rbconfig'
require 'rubygems/version'
require 'time'
require 'uri'

module Mxrb
  module CLI
    class ReleaseError < StandardError; end

    ReleaseStatus = Data.define(:installed, :latest, :checked_at) do
      def available?
        latest && Gem::Version.new(latest) > Gem::Version.new(installed)
      rescue ArgumentError
        false
      end
    end

    # Checks RubyGems for versions and GitHub Releases for human release notes.
    class Releases
      LATEST_URI = URI('https://rubygems.org/api/v1/versions/mxrb/latest.json')
      RELEASE_URI = 'https://api.github.com/repos/lucamykael/mxrb/releases/tags/v%s'
      CACHE_TTL = 6 * 60 * 60

      def initialize(installed: Mxrb::VERSION, cache_path: nil, clock: Time.method(:now), request: nil)
        @installed = installed.to_s
        @cache_path = cache_path || default_cache_path
        @clock = clock
        @request = request || method(:http_get)
      end

      def status(force: false)
        payload = !force && read_cache
        payload ||= fetch_latest
        ReleaseStatus.new(@installed, payload && payload['version'], payload && payload['checked_at'])
      rescue ReleaseError, JSON::ParserError, IOError, SystemCallError, Timeout::Error, SocketError
        ReleaseStatus.new(@installed, nil, nil)
      end

      def changelog(version = nil) # rubocop:disable Metrics/AbcSize
        selected = version.to_s.empty? ? status(force: true).latest : version.to_s
        raise ReleaseError, 'Could not determine the latest published MXRB version' if selected.to_s.empty?

        payload = JSON.parse(@request.call(URI(format(RELEASE_URI, selected))))
        {
          version: selected, title: payload['name'] || "mxrb #{selected}",
          published_at: payload['published_at'], body: payload['body'].to_s,
          url: payload['html_url'] || "https://github.com/lucamykael/mxrb/releases/tag/v#{selected}"
        }
      rescue ReleaseError, JSON::ParserError, IOError, SystemCallError, Timeout::Error, SocketError => e
        raise ReleaseError, "Could not load changelog: #{e.message}"
      end

      private

      def fetch_latest
        data = JSON.parse(@request.call(LATEST_URI))
        payload = { 'version' => data.fetch('version').to_s, 'checked_at' => @clock.call.utc.iso8601 }
        write_cache(payload)
        payload
      end

      def read_cache
        return unless File.file?(@cache_path)

        payload = JSON.parse(File.read(@cache_path))
        checked_at = Time.iso8601(payload.fetch('checked_at'))
        payload if @clock.call - checked_at < CACHE_TTL
      rescue KeyError, ArgumentError
        nil
      end

      def write_cache(payload)
        FileUtils.mkdir_p(File.dirname(@cache_path))
        temporary = "#{@cache_path}.#{Process.pid}.tmp"
        File.write(temporary, JSON.generate(payload))
        File.rename(temporary, @cache_path)
      ensure
        FileUtils.rm_f(temporary) if temporary
      end

      def default_cache_path
        base = ENV['XDG_CACHE_HOME'].to_s
        base = File.join(Dir.home, '.cache') if base.empty?
        File.join(base, 'mxrb', 'release.json')
      end

      def http_get(uri)
        request = Net::HTTP::Get.new(uri)
        request['Accept'] = 'application/json'
        request['User-Agent'] = "mxrb/#{Mxrb::VERSION}"
        response = Net::HTTP.start(
          uri.host, uri.port, use_ssl: true, open_timeout: 1.5, read_timeout: 2.0
        ) { _1.request(request) }
        raise ReleaseError, "release service returned HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

        response.body
      end
    end

    # Installs a published release while refusing to overwrite a source checkout.
    class Updater
      def initialize(releases: Releases.new, runner: Kernel.method(:system), source_root: nil, env: ENV)
        @releases = releases
        @runner = runner
        @source_root = source_root || File.expand_path('../../..', __dir__)
        @env = env
      end

      def update!
        status = @releases.status(force: true)
        raise ReleaseError, 'Could not check the latest published MXRB version' unless status.latest
        return status unless status.available?
        raise ReleaseError, checkout_message if source_checkout?

        command = bundled? ? %w[bundle update mxrb] : [RbConfig.ruby, '-S', 'gem', 'update', 'mxrb', '--no-document']
        raise ReleaseError, "Update command failed: #{command.join(' ')}" unless @runner.call(*command)

        status
      end

      private

      def source_checkout? = File.directory?(File.join(@source_root, '.git'))
      def bundled? = !@env['BUNDLE_GEMFILE'].to_s.empty?

      def checkout_message
        'This MXRB executable comes from a source checkout. Update it with `git pull` and `bundle install`; ' \
          'the CLI will not overwrite local source files.'
      end
    end
  end
end
