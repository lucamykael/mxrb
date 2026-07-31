# frozen_string_literal: true

module Mxrb
  module OfficialMarketplace
    # Client and resolver for the documented Mendix Marketplace Content API.
    class ContentApi # rubocop:disable Metrics/ClassLength
      BASE_URL = 'https://marketplace-api.mendix.com/v1'
      AUTHORIZED_HOSTS = %w[marketplace-api.mendix.com marketplace.mendix.com].freeze
      CONTENT_LIMIT = 100
      VERSION_LIMIT = 20
      MENDIX_VERSION = /\A(?:\d{1,3}|1000)(?:\.(?:\d{1,3}|1000)){0,2}\z/
      UUID = /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/i

      def initialize(pat: nil, credentials: Credentials.new, client: HttpClient.new)
        @pat = pat.to_s.strip
        @pat = ENV['MXRB_MENDIX_PAT'].to_s.strip if @pat.empty?
        @pat = credentials.pat.to_s.strip if @pat.empty?
        raise MarketplaceError, missing_pat_message if @pat.empty?

        @client = client
      end

      def search(name: nil, private: nil, approved: nil, published_since: nil, # rubocop:disable Metrics/ParameterLists
                 limit: 10, offset: 0)
        parameters = {
          name:, isPrivate: boolean_filter(private), isCompanyApproved: boolean_filter(approved),
          publishedSince: date_filter(published_since), limit: bounded_integer(limit, 1..CONTENT_LIMIT),
          offset: bounded_integer(offset, 0..)
        }.compact
        items(request('/content', parameters))
      end

      def content(content_id)
        identifier = positive_integer(content_id, 'content ID')
        request("/content/#{identifier}")
      end

      def versions(content_id, version_id: nil, mendix_version: nil, published_since: nil, # rubocop:disable Metrics/ParameterLists
                   limit: VERSION_LIMIT, offset: 0)
        identifier = positive_integer(content_id, 'content ID')
        parameters = {
          versionId: uuid_filter(version_id),
          supportedMendixVersion: mendix_version_filter(mendix_version),
          publishedSince: date_filter(published_since),
          limit: bounded_integer(limit, 1..VERSION_LIMIT), offset: bounded_integer(offset, 0..)
        }.compact
        items(request("/content/#{identifier}/versions", parameters))
      end

      def find(identifier)
        return content(identifier) if identifier.to_s.match?(/\A\d+\z/)

        candidates(identifier).each do |name|
          matches = search(name:)
          return matches.first if matches.one?
          raise MarketplaceError, "Marketplace content name #{name.inspect} is ambiguous" \
            if matches.length > 1
        end
        raise MarketplaceError, "Marketplace content not found: #{identifier.inspect}"
      end

      def resolve(identifier, version: nil, mendix_version: nil, allow_vulnerable: false)
        selected_content = find(identifier)
        selected_version = resolve_version(selected_content.fetch('contentId'), version, mendix_version)
        ensure_compatible!(selected_version, mendix_version) if mendix_version
        reject_vulnerable!(selected_version) unless allow_vulnerable
        package(selected_content, selected_version)
      end

      def download(version_id, destination, download_url: nil)
        identifier = uuid_filter(version_id)
        url = download_url || "#{BASE_URL}/versions/#{identifier}/download"
        uri = URI.parse(url)
        trusted = AUTHORIZED_HOSTS.include?(uri.host)
        @client.download(url, destination, authorization: trusted ? authorization : nil)
      end

      def all_versions(content_id, published_since: nil)
        paginated(VERSION_LIMIT) do |limit, offset|
          versions(content_id, published_since:, limit:, offset:)
        end
      end

      private

      def request(path, parameters = {})
        @client.json(url(path, parameters), authorization: authorization)
      end

      def authorization = "MxToken #{@pat}"

      def url(path, parameters)
        query = URI.encode_www_form(parameters)
        query.empty? ? "#{BASE_URL}#{path}" : "#{BASE_URL}#{path}?#{query}"
      end

      def items(payload)
        value = payload.fetch('items', [])
        raise MarketplaceError, 'invalid Marketplace Content API response: items must be an array' \
          unless value.is_a?(Array)

        value
      end

      def resolve_version(content_id, version, mendix_version)
        values = version_candidates(content_id, version, mendix_version)
        raise MarketplaceError, version_not_found_message(version, mendix_version) if values.empty?

        values.max_by { version_key(_1) }
      end

      def version_candidates(content_id, version, mendix_version)
        return versions(content_id, version_id: version) if version&.match?(UUID)
        return all_versions(content_id).select { _1['versionNumber'].to_s == version } if version
        return versions(content_id, mendix_version:) if mendix_version

        versions(content_id)
      end

      def package(content, version)
        OfficialPackage.new(
          version['name'] || content.dig('latestVersion', 'name') || "Content#{content['contentId']}",
          version.fetch('versionNumber'), :mendix, version['downloadURL'] || version['downloadUrl'],
          "content:#{content.fetch('contentId')}", content.fetch('contentId'),
          version.fetch('versionId'), content.fetch('type'), version['versionType'] || 'Regular',
          security_codes(version), content['isPrivate'], content['isCompanyApproved']
        )
      end

      def reject_vulnerable!(version)
        return unless version['versionType'] == 'Vulnerable'

        codes = security_codes(version)
        suffix = codes.empty? ? '' : " (#{codes.join(', ')})"
        raise MarketplaceError,
              "Marketplace version #{version['versionNumber']} is marked vulnerable#{suffix}; " \
              'select a security fix or pass --allow-vulnerable'
      end

      def ensure_compatible!(version, mendix_version)
        minimum = version['minSupportedMendixVersion'].to_s
        compatible = !minimum.empty? && Gem::Version.new(mendix_version) >= Gem::Version.new(minimum)
        return if compatible

        raise MarketplaceError,
              "Marketplace version #{version['versionNumber']} requires Mendix #{minimum} or newer"
      end

      def security_codes(version)
        issues = Array(version['vulnerabilities']) + Array(version['fixedSecurityIssues'])
        issues.filter_map { _1['code'] }.uniq
      end

      def candidates(identifier)
        name = identifier.to_s.strip
        raise MarketplaceError, 'Marketplace content name must not be empty' if name.empty?

        spaced = name.gsub(/([a-z\d])([A-Z])/, '\\1 \\2').tr('_-', ' ').squeeze(' ')
        [name, spaced].uniq
      end

      def paginated(page_size)
        offset = 0
        result = []
        loop do
          page = yield(page_size, offset)
          result.concat(page)
          break if page.length < page_size

          offset += page_size
        end
        result
      end

      def version_key(value)
        [value['publicationDate'].to_s, Gem::Version.new(normalize_version(value['versionNumber']))]
      end

      def normalize_version(value)
        value.to_s[/\A\d+(?:\.\d+){0,2}/] || '0'
      end

      def boolean_filter(value)
        return if value.nil?
        return value.to_s if [true, false].include?(value)
        return value if %w[true false].include?(value)

        raise MarketplaceError, "expected true or false, got #{value.inspect}"
      end

      def date_filter(value)
        return if value.nil?

        Date.iso8601(value.to_s).iso8601
      rescue Date::Error
        raise MarketplaceError, "invalid RFC 3339 full date #{value.inspect}"
      end

      def uuid_filter(value)
        return if value.nil?
        raise MarketplaceError, "invalid Marketplace version ID #{value.inspect}" unless value.to_s.match?(UUID)

        value.to_s
      end

      def mendix_version_filter(value)
        return if value.nil?
        raise MarketplaceError, "invalid Mendix version #{value.inspect}" unless value.to_s.match?(MENDIX_VERSION)

        value.to_s
      end

      def bounded_integer(value, range)
        integer = Integer(value)
        raise MarketplaceError, "value #{value.inspect} is outside #{range}" unless range.cover?(integer)

        integer
      rescue ArgumentError, TypeError
        raise MarketplaceError, "expected an integer, got #{value.inspect}"
      end

      def positive_integer(value, label)
        integer = bounded_integer(value, 1..)
        integer.to_s
      rescue MarketplaceError
        raise MarketplaceError, "invalid #{label} #{value.inspect}"
      end

      def version_not_found_message(version, mendix_version)
        qualifier = if version
                      "version #{version.inspect}"
                    elsif mendix_version
                      "a version compatible with Mendix #{mendix_version}"
                    else
                      'a published version'
                    end
        "Marketplace content does not have #{qualifier}"
      end

      def missing_pat_message
        'Mendix PAT not found; run `mxrb marketplace login` with scope mx:marketplace-content:read'
      end
    end # rubocop:enable Metrics/ClassLength

    AuditResult = Data.define(
      :name, :installed_version, :latest_version, :version_type, :issues, :outdated, :valid
    )

    # Reviews Content API-backed lock entries for updates and known vulnerabilities.
    class SecurityAuditor
      def initialize(target:, api: nil)
        @target = File.expand_path(target)
        @api = api
      end

      def audit(mendix_version: nil)
        entries = OfficialMarketplace.lock(@target).fetch('packages').select do |_name, entry|
          entry['source'] == 'mendix' && entry['content_id']
        end
        return [] if entries.empty?

        @api ||= ContentApi.new
        entries.map do |name, entry|
          audit_entry(name, entry, mendix_version)
        end
      end

      private

      def audit_entry(name, entry, mendix_version)
        installed = @api.versions(entry.fetch('content_id'), version_id: entry['version_id']).first
        latest = @api.resolve(entry.fetch('content_id').to_s, mendix_version:, allow_vulnerable: true)
        type, issues, installed_version = installed_metadata(installed, entry)
        AuditResult.new(
          name, installed_version, latest.version, type, issues,
          installed_version != latest.version, !installed.nil? && type != 'Vulnerable'
        )
      end

      def installed_metadata(installed, entry)
        type = installed&.fetch('versionType', nil) || 'Unknown'
        issues = Array(installed&.fetch('vulnerabilities', nil)).filter_map { _1['code'] }
        version = installed&.fetch('versionNumber', nil) || entry['version']
        [type, issues, version]
      end
    end
  end
end
