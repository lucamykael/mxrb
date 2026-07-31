# frozen_string_literal: true

require 'digest'
require 'date'
require 'fileutils'
require 'json'
require 'net/http'
require 'tmpdir'
require 'uri'
require 'zip'
require_relative 'official_marketplace/module_package_importer'

module Mxrb
  # Installer for official/community Mendix packages, separate from Ruby modules.
  module OfficialMarketplace
    Package = Data.define(:name, :version, :source, :download_url, :repository)
    OfficialPackage = Data.define(
      :name, :version, :source, :download_url, :repository, :content_id, :version_id,
      :content_type, :version_type, :security_issues, :private, :company_approved
    )
    Installation = Data.define(:package, :destination, :sha256)
    ModuleInstallation = Data.define(
      :package, :destination, :sha256, :module_name, :module_id, :units, :files, :archive
    )

    CATALOG = {
      'CommunityCommons' => 'mendix/CommunityCommons',
      'UnitTesting' => 'mendix/UnitTesting'
    }.freeze

    def self.tree_digest(path)
      digest = Digest::SHA256.new
      Dir.glob(File.join(path, '**', '*'), File::FNM_DOTMATCH).sort.each do |file|
        next unless File.file?(file)

        digest << file.delete_prefix("#{path}/") << "\0" << File.binread(file)
      end
      digest.hexdigest
    end

    def self.lock(target)
      path = File.join(File.expand_path(target), '.mxrb', 'marketplace.lock.json')
      File.file?(path) ? JSON.parse(File.read(path)) : { 'packages' => {} }
    rescue JSON::ParserError => e
      raise MarketplaceError, "invalid marketplace lockfile: #{e.message}"
    end

    def self.verify(target)
      root = File.expand_path(target)
      lock(root).fetch('packages').to_h do |name, entry|
        result = entry['kind'] == 'module' ? verify_module(root, name, entry) : verify_tree(root, entry)
        [name, result]
      end
    end

    def self.verify_tree(root, entry)
      destination = File.join(root, entry.fetch('destination'))
      actual = File.directory?(destination) ? tree_digest(destination) : nil
      { valid: actual == entry['sha256'], expected: entry['sha256'], actual: }
    end

    def self.verify_module(root, name, entry) # rubocop:disable Metrics/AbcSize
      archive = File.join(root, entry.fetch('archive'))
      actual = File.file?(archive) ? Digest::SHA256.file(archive).hexdigest : nil
      mpr_path = File.join(root, entry.fetch('destination'))
      present = module_present?(mpr_path, name, entry['module_id'])
      files_present = Array(entry['files']).all? { File.file?(File.join(root, _1)) }
      {
        valid: actual == entry['sha256'] && present && files_present,
        expected: entry['sha256'], actual:, module_present: present, files_present:
      }
    end

    def self.module_present?(mpr_path, name, module_id)
      return false unless File.file?(mpr_path)

      mpr = IO::MprFile.open(mpr_path, readonly: true)
      unit = module_id ? mpr.unit(module_id) : module_by_name(mpr, name)
      unit && mpr.parse_contents(unit)['Name'] == name
    rescue Error, SQLite3::Exception
      false
    ensure
      mpr&.close
    end

    def self.module_by_name(mpr, name)
      mpr.units_by_containment('Modules').find { mpr.parse_contents(_1)['Name'] == name }
    end

    # Stores the Mendix PAT outside projects with owner-only permissions.
    class Credentials
      def initialize(path: nil)
        base = ENV['XDG_CONFIG_HOME'].to_s
        base = File.join(Dir.home, '.config') if base.empty?
        @path = path || File.join(base, 'mxrb', 'credentials')
      end

      def save_pat(token)
        value = token.to_s.strip
        raise MarketplaceError, 'Mendix PAT must not be empty' if value.empty?

        FileUtils.mkdir_p(File.dirname(@path), mode: 0o700)
        temporary = "#{@path}.tmp-#{Process.pid}"
        File.binwrite(temporary, JSON.generate('mendix_pat' => value) << "\n")
        File.chmod(0o600, temporary)
        File.rename(temporary, @path)
        @path
      ensure
        FileUtils.rm_f(temporary) if defined?(temporary) && temporary && File.exist?(temporary)
      end

      def pat
        return unless File.file?(@path)

        JSON.parse(File.binread(@path))['mendix_pat']
      rescue JSON::ParserError => e
        raise MarketplaceError, "invalid credentials file: #{e.message}"
      end
    end

    # Small HTTPS-only GitHub client with bounded redirects and response size.
    class HttpClient
      MAX_BYTES = 512 * 1024 * 1024

      def initialize(github_token: ENV['GITHUB_TOKEN'])
        @github_token = github_token.to_s
      end

      def json(url, authorization: default_authorization)
        JSON.parse(get(url, accept: 'application/json', authorization:))
      rescue JSON::ParserError => e
        raise MarketplaceError, "invalid JSON response: #{e.message}"
      end

      def download(url, destination, authorization: default_authorization)
        File.binwrite(destination, get(url, accept: 'application/octet-stream', authorization:))
        destination
      end

      private

      def get(url, accept:, redirects: 5, authorization: default_authorization,
              authorization_host: nil)
        raise MarketplaceError, 'too many marketplace redirects' if redirects.negative?

        uri = https_uri(url)
        authorization_host ||= uri.host
        scoped_authorization = authorization if uri.host == authorization_host
        response = perform(uri, accept, scoped_authorization)
        return response_body(response) unless response.is_a?(Net::HTTPRedirection)

        options = { accept:, redirects: redirects - 1, authorization:, authorization_host: }
        follow_redirect(uri, response, options)
      rescue URI::InvalidURIError, SocketError, SystemCallError => e
        raise MarketplaceError, "marketplace request failed: #{e.message}"
      end

      def follow_redirect(uri, response, options)
        get(
          URI.join(uri, response['location']).to_s, **options
        )
      end

      def https_uri(url)
        URI.parse(url).tap do |uri|
          raise MarketplaceError, 'marketplace downloads require HTTPS' unless uri.is_a?(URI::HTTPS)
        end
      end

      def perform(uri, accept, authorization = default_authorization)
        request = Net::HTTP::Get.new(uri)
        request['Accept'] = accept
        request['User-Agent'] = "mxrb/#{Mxrb::VERSION}"
        request['Authorization'] = authorization unless authorization.to_s.empty?
        Net::HTTP.start(uri.host, uri.port, use_ssl: true) { _1.request(request) }
      end

      def default_authorization
        "Bearer #{@github_token}" unless @github_token.empty?
      end

      def response_body(response)
        unless response.is_a?(Net::HTTPSuccess)
          raise MarketplaceError, "marketplace request failed with HTTP #{response.code}"
        end
        raise MarketplaceError, 'marketplace response exceeds 512 MiB' \
          if response.body.to_s.bytesize > MAX_BYTES

        response.body
      end
    end

    require_relative 'official_marketplace/content_api'

    # Resolves known names or explicit github:org/repo releases.
    class GitHubResolver
      def initialize(client: HttpClient.new)
        @client = client
      end

      def search(query)
        local = catalog_search(query)
        return local unless local.empty?

        github_search(query)
      end

      def catalog_search(query)
        term = query.to_s.downcase
        CATALOG.filter_map do |name, repository|
          { name:, repository: } if name.downcase.include?(term) || repository.downcase.include?(term)
        end
      end

      def github_search(query)
        payload = @client.json(
          "https://api.github.com/search/repositories?q=#{URI.encode_www_form_component(query)}+org:mendix"
        )
        Array(payload['items']).first(20).map do |item|
          { name: item['name'], repository: item['full_name'], description: item['description'] }
        end
      end

      def resolve(identifier, version: nil)
        repository, name = repository_and_name(identifier)
        endpoint = release_endpoint(version)
        release = @client.json("https://api.github.com/repos/#{repository}/#{endpoint}")
        download_url = release_download(release)
        Package.new(name, release['tag_name'] || version || 'latest', :github, download_url, repository)
      rescue KeyError => e
        raise MarketplaceError, "GitHub release is incomplete: #{e.message}"
      end

      private

      def release_endpoint(version)
        version ? "releases/tags/#{URI.encode_www_form_component(version)}" : 'releases/latest'
      end

      def release_download(release)
        assets = Array(release['assets'])
        asset = %w[.mpk .zip].filter_map do |extension|
          assets.find { _1['name'].to_s.downcase.end_with?(extension) }
        end.first
        asset ? asset.fetch('browser_download_url') : release.fetch('zipball_url')
      end

      def repository_and_name(identifier)
        source = identifier.to_s.delete_prefix('github:')
        repository = source.include?('/') ? source : CATALOG[source]
        raise MarketplaceError, "no GitHub repository is known for #{identifier.inspect}" unless repository

        [repository, source.split('/').last]
      end
    end

    # Safely extracts GitHub or local MPK archives into the target project.
    class Installer # rubocop:disable Metrics/ClassLength
      def initialize(target:, client: HttpClient.new, mpr: nil)
        @target = File.expand_path(target)
        @client = client
        @mpr = mpr && File.expand_path(mpr)
      end

      def pull(identifier, version: nil, mpr: @mpr)
        package = GitHubResolver.new(client: @client).resolve(identifier, version:)
        Dir.mktmpdir('mxrb-marketplace-') do |dir|
          archive = @client.download(package.download_url, File.join(dir, 'package.zip'))
          mpr ? import_module(archive, package, mpr) : install_archive(archive, package)
        end
      end

      def pull_official(identifier, version: nil, mendix_version: nil,
                        allow_vulnerable: false, api: ContentApi.new)
        mpr = @mpr
        raise MarketplaceError, 'official Marketplace module pull requires --mpr FILE.mpr' unless mpr

        mendix_version ||= detect_mendix_version(mpr)
        package = api.resolve(identifier, version:, mendix_version:, allow_vulnerable:)
        validate_official_package!(package)
        download_official(package, mpr, api)
      end

      def download_official(package, mpr, api)
        Dir.mktmpdir('mxrb-marketplace-') do |dir|
          archive = api.download(
            package.version_id, File.join(dir, 'package.mpk'), download_url: package.download_url
          )
          import_module(archive, package, mpr)
        end
      end

      def validate_official_package!(package)
        return if package.content_type == 'Module'

        raise MarketplaceError,
              "Marketplace content #{package.name.inspect} is #{package.content_type}, not a Module"
      end

      def import(path, name: nil, mpr: @mpr)
        source = File.expand_path(path)
        raise MarketplaceError, "package not found: #{source}" unless File.file?(source)

        package_name = valid_name(name || File.basename(source, File.extname(source)))
        package = Package.new(package_name, 'local', :mpk, source, nil)
        mpr ? import_module(source, package, mpr) : install_archive(source, package)
      end

      private

      def detect_mendix_version(mpr)
        file = IO::MprFile.open(mpr, readonly: true)
        file.mendix_version
      ensure
        file&.close
      end

      def import_module(archive, package, mpr)
        relative_target_path(mpr)
        result = ModulePackageImporter.new(archive, mpr, target_root: @target).import!
        resolved = resolved_package(package, result)
        sha256 = Digest::SHA256.file(archive).hexdigest
        cached = cache_package(archive, resolved, sha256)
        write_module_lock(resolved, mpr, result, cached, sha256)
        ModuleInstallation.new(
          resolved, File.expand_path(mpr), sha256, result.module_name, result.module_id,
          result.units, result.files, cached
        )
      end

      def resolved_package(package, result)
        version = result.package_version.to_s.empty? ? package.version : result.package_version
        values = { name: result.module_name, version: }
        return package.with(**values) if package.respond_to?(:content_id)

        Package.new(
          values.fetch(:name), values.fetch(:version), package.source,
          package.download_url, package.repository
        )
      end

      def cache_package(archive, package, sha256)
        version = package.version.to_s.gsub(/[^A-Za-z0-9_.-]/, '_')
        destination = File.join(@target, '.mxrb', 'marketplace', "#{package.name}-#{version}.mpk")
        FileUtils.mkdir_p(File.dirname(destination))
        FileUtils.cp(archive, destination) unless File.expand_path(archive) == destination
        raise MarketplaceError, 'cached marketplace package checksum mismatch' unless
          Digest::SHA256.file(destination).hexdigest == sha256

        destination
      end

      def write_module_lock(package, mpr, result, cached, digest) # rubocop:disable Metrics/AbcSize
        path = File.join(@target, '.mxrb', 'marketplace.lock.json')
        FileUtils.mkdir_p(File.dirname(path))
        lock = OfficialMarketplace.lock(@target)
        lock['packages'][package.name] = {
          'kind' => 'module', 'version' => package.version, 'source' => package.source,
          'repository' => package.repository, 'sha256' => digest,
          'destination' => relative_target_path(mpr), 'archive' => relative_target_path(cached),
          'module_id' => result.module_id, 'units' => result.units, 'files' => result.files
        }.merge(official_lock_metadata(package)).compact
        write_lock_atomically(path, lock)
      end

      def official_lock_metadata(package)
        return {} unless package.respond_to?(:content_id)

        {
          'content_id' => package.content_id, 'version_id' => package.version_id,
          'content_type' => package.content_type, 'version_type' => package.version_type,
          'security_issues' => package.security_issues, 'private' => package.private,
          'company_approved' => package.company_approved
        }
      end

      def relative_target_path(path)
        absolute = File.expand_path(path)
        prefix = "#{@target}#{File::SEPARATOR}"
        raise MarketplaceError, "path is outside marketplace target: #{absolute}" unless absolute.start_with?(prefix)

        absolute.delete_prefix(prefix)
      end

      # Transaction boundary intentionally keeps rollback and cleanup together.
      # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
      def install_archive(archive, package)
        name = valid_name(package.name)
        destination = File.join(@target, 'modules', name)
        raise MarketplaceError, "module destination already exists: #{destination}" if File.exist?(destination)

        staging = File.join(@target, '.mxrb', 'marketplace-staging', "#{name}-#{Process.pid}")
        extract_zip(archive, staging)
        move_into_project(staging, destination)
        digest = OfficialMarketplace.tree_digest(destination)
        write_lock(package, destination, digest)
        Installation.new(package, destination, digest)
      rescue StandardError
        FileUtils.rm_rf(destination) if defined?(destination) && destination && File.exist?(destination)
        raise
      ensure
        FileUtils.rm_rf(staging) if defined?(staging) && staging && File.exist?(staging)
      end
      # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

      def extract_zip(archive, staging)
        FileUtils.mkdir_p(staging)
        Zip::File.open(archive) do |zip|
          zip.each { extract_safe_entry(_1, staging) }
        end
      rescue Zip::Error => e
        raise MarketplaceError, "invalid MPK/ZIP package: #{e.message}"
      end

      def extract_safe_entry(entry, staging)
        destination = safe_destination(entry.name, staging)

        entry.directory? ? FileUtils.mkdir_p(destination) : extract_entry(entry, destination)
      end

      def safe_destination(name, staging)
        relative = name.to_s
        unsafe = relative.start_with?('/', '\\') || relative.split(%r{[\\/]}).include?('..')
        raise MarketplaceError, "unsafe package path #{name.inspect}" if unsafe

        destination = File.expand_path(File.join(staging, relative))
        prefix = "#{File.expand_path(staging)}#{File::SEPARATOR}"
        raise MarketplaceError, "unsafe package path #{name.inspect}" unless destination.start_with?(prefix)

        destination
      end

      def extract_entry(entry, destination)
        FileUtils.mkdir_p(File.dirname(destination))
        File.open(destination, 'wb') { ::IO.copy_stream(entry.get_input_stream, _1) }
      end

      def collapse_single_root(staging)
        children = Dir.children(staging)
        if children.one? && File.directory?(File.join(staging, children.first))
          return File.join(staging, children.first)
        end

        staging
      end

      def move_into_project(staging, destination)
        FileUtils.mkdir_p(File.dirname(destination))
        FileUtils.mv(collapse_single_root(staging), destination)
      end

      def valid_name(value)
        name = value.to_s.gsub(/[^A-Za-z0-9_]/, '')
        raise MarketplaceError, "invalid marketplace module name #{value.inspect}" \
          unless name.match?(/\A[A-Za-z][A-Za-z0-9_]*\z/)

        name
      end

      def write_lock(package, destination, digest)
        path = File.join(@target, '.mxrb', 'marketplace.lock.json')
        FileUtils.mkdir_p(File.dirname(path))
        lock = OfficialMarketplace.lock(@target)
        lock['packages'][package.name] = lock_entry(package, destination, digest)
        write_lock_atomically(path, lock)
      end

      def lock_entry(package, destination, digest)
        {
          'version' => package.version, 'source' => package.source,
          'repository' => package.repository, 'sha256' => digest,
          'destination' => destination.delete_prefix("#{@target}/")
        }.merge(official_lock_metadata(package)).compact
      end

      def write_lock_atomically(path, lock)
        temporary = "#{path}.tmp-#{Process.pid}"
        File.write(temporary, JSON.pretty_generate(lock) << "\n")
        File.rename(temporary, path)
      ensure
        FileUtils.rm_f(temporary) if defined?(temporary) && temporary && File.exist?(temporary)
      end
    end
  end
end
