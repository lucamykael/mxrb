# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'
require 'uri'

module Mxrb
  module TeamServer
    HOST = 'git.api.mendix.com'
    API_BASE = 'https://repository.api.mendix.com/v1'
    APP_ID = /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/i

    CloneResult = Data.define(:root, :repository_url, :branch, :mpr_files)
    GitResult = Data.define(:output, :repository_url)

    # Stores only a reference to a user-managed PAT file.
    class Credentials
      attr_reader :path

      def initialize(path: nil, pat_file: ENV['MXRB_TEAM_SERVER_PAT_FILE'])
        base = ENV['XDG_CONFIG_HOME'].to_s
        base = File.join(Dir.home, '.config') if base.empty?
        @path = File.expand_path(path || File.join(base, 'mxrb', 'credentials'))
        @pat_file = expand(pat_file)
      end

      def configure_pat_file(source)
        @pat_file = expand(source)
        raise TeamServerError, 'Team Server PAT file path must not be empty' unless @pat_file

        read_pat_file(@pat_file)
        config = File.file?(@path) ? read_config : {}
        config.delete('team_server_pat')
        write_config(config.merge('team_server_pat_file' => @pat_file))
      end

      def pat
        source = @pat_file
        source ||= expand(read_config['team_server_pat_file']) if File.file?(@path)
        source && read_pat_file(source)
      end

      private

      def expand(value)
        value = value.to_s.strip
        value.empty? ? nil : File.expand_path(value)
      end

      def read_config
        value = JSON.parse(File.binread(@path))
        raise TeamServerError, 'invalid credentials file: expected a JSON object' unless value.is_a?(Hash)

        value
      rescue JSON::ParserError => e
        raise TeamServerError, "invalid credentials file: #{e.message}"
      end

      def write_config(value)
        FileUtils.mkdir_p(File.dirname(@path), mode: 0o700)
        temporary = "#{@path}.tmp-#{Process.pid}"
        File.binwrite(temporary, JSON.generate(value) << "\n")
        File.chmod(0o600, temporary)
        File.rename(temporary, @path)
        @path
      ensure
        FileUtils.rm_f(temporary) if defined?(temporary) && temporary
      end

      def read_pat_file(source)
        raise TeamServerError, "Team Server PAT file not found: #{source}" unless File.file?(source)

        raw = File.binread(source).strip
        value = extract_pat(raw, source)
        raise TeamServerError, "Team Server PAT file is empty: #{source}" if value.empty?

        value
      rescue SystemCallError => e
        raise TeamServerError, "cannot read Team Server PAT file #{source}: #{e.message}"
      end

      def extract_pat(raw, source)
        return extract_env_pat(raw, source) if env_file?(raw, source)

        parsed = JSON.parse(raw)
        return parsed.fetch('team_server_pat', parsed['mendix_pat']).to_s.strip if parsed.is_a?(Hash)

        raise TeamServerError, 'JSON Team Server PAT file must contain team_server_pat'
      rescue JSON::ParserError
        raw
      end

      def env_file?(raw, source)
        File.basename(source).start_with?('.env') || raw.match?(/MXRB_(?:TEAM_SERVER|MENDIX)_PAT\s*=/)
      end

      def extract_env_pat(raw, source)
        pattern = /^\s*(?:export\s+)?MXRB_(?:TEAM_SERVER|MENDIX)_PAT\s*=/
        line = raw.lines.reverse.find { _1.match?(pattern) }
        raise TeamServerError, "Team Server PAT variable not found in #{source}" unless line

        unquote(line.sub(pattern, '').strip)
      end

      def unquote(value)
        return value unless value.length >= 2 && %w[' "].include?(value[0]) && value[-1] == value[0]

        value[1...-1]
      end
    end

    # Injectable subprocess boundary used by the Git transport.
    class CommandRunner
      def capture(environment, command, chdir: nil)
        options = chdir ? { chdir: } : {}
        Open3.capture2e(environment, *command, **options)
      end
    end

    # Provides Git's credentials through an ephemeral askpass script.
    class GitAuthenticator
      def initialize(credentials)
        @credentials = credentials
      end

      def call
        token = @credentials.pat
        return yield('GIT_TERMINAL_PROMPT' => '0') unless token

        Dir.mktmpdir('mxrb-askpass-') do |dir|
          helper = write_helper(dir)
          yield authenticated_environment(helper, token)
        end
      end

      private

      def write_helper(dir)
        helper = File.join(dir, 'askpass')
        File.write(helper, <<~SH)
          #!/bin/sh
          case "$1" in
            *Username*) printf '%s\\n' pat ;;
            *Password*) printf '%s\\n' "$MXRB_TEAM_SERVER_PAT" ;;
            *) exit 1 ;;
          esac
        SH
        File.chmod(0o700, helper)
        helper
      end

      def authenticated_environment(helper, token)
        {
          'GIT_ASKPASS' => helper, 'GIT_ASKPASS_REQUIRE' => 'force',
          'GIT_TERMINAL_PROMPT' => '0', 'MXRB_TEAM_SERVER_PAT' => token
        }
      end
    end

    # Git transport for Team Server. PATs are passed to a short-lived
    # GIT_ASKPASS process and are never embedded in a URL or git config.
    class Repository
      def initialize(credentials: Credentials.new, runner: CommandRunner.new,
                     authenticator: GitAuthenticator.new(credentials))
        @runner = runner
        @authenticator = authenticator
      end

      def clone(source, target:, branch: nil, depth: nil)
        url = self.class.repository_url(source)
        root = File.expand_path(target)
        raise TeamServerError, "#{root}: destination already exists" if File.exist?(root)

        capture!(clone_arguments(url, root, branch:, depth:))
        mprs = postprocess_clone(root)
        CloneResult.new(root:, repository_url: url, branch:, mpr_files: mprs)
      rescue StandardError
        FileUtils.rm_rf(root) if defined?(root) && root && File.directory?(root) && !File.exist?(File.join(root,
                                                                                                           '.git'))
        raise
      end

      def fetch(root, prune: true)
        repository = repository_root(root)
        args = %w[git fetch]
        args << '--prune' if prune
        output = capture!(args, chdir: repository)
        GitResult.new(output:, repository_url: remote_url(repository))
      end

      def pull(root, ff_only: true)
        repository = repository_root(root)
        args = %w[git pull]
        args << '--ff-only' if ff_only
        output = capture!(args, chdir: repository)
        validate_mprs!(repository)
        GitResult.new(output:, repository_url: remote_url(repository))
      end

      def push(root, remote: 'origin', branch: nil)
        repository = repository_root(root)
        args = ['git', 'push', '--', remote.to_s]
        args << branch.to_s if branch
        output = capture!(args, chdir: repository)
        GitResult.new(output:, repository_url: remote_url(repository, remote:))
      end

      def status(root)
        repository = repository_root(root)
        capture!(['git', 'status', '--short', '--branch'], chdir: repository)
      end

      def self.repository_url(source)
        value = source.to_s.strip
        value = "https://#{HOST}/#{value}.git" if value.match?(APP_ID)
        uri = URI.parse(value)
        raise TeamServerError, "invalid Team Server Git URL: #{source.inspect}" unless valid_repository_uri?(uri)

        uri.to_s
      rescue URI::InvalidURIError
        raise TeamServerError, "invalid Team Server Git URL: #{source.inspect}"
      end

      private

      def self.valid_repository_uri?(uri)
        uri.scheme == 'https' && uri.host == HOST && uri.userinfo.nil? &&
          uri.path.match?(%r{\A/[0-9a-f-]{36}\.git\z}i) && uri.query.nil? && uri.fragment.nil?
      end

      private_class_method :valid_repository_uri?

      def clone_arguments(url, root, branch:, depth:)
        arguments = %w[git clone]
        arguments += ['--branch', branch.to_s] if branch
        arguments += ['--depth', positive_depth(depth).to_s] if depth
        arguments + ['--', url, root]
      end

      def positive_depth(value)
        depth = Integer(value)
        raise ArgumentError unless depth.positive?

        depth
      rescue ArgumentError, TypeError
        raise TeamServerError, 'clone depth must be a positive integer'
      end

      def capture!(command, chdir: nil)
        @authenticator.call do |environment|
          output, status = @runner.capture(environment, command, chdir:)
          raise TeamServerError, "Team Server Git operation failed: #{output.strip}" unless status.success?

          output
        end
      end

      def repository_root(root)
        path = File.expand_path(root)
        raise TeamServerError, "#{path}: not a Git repository" unless File.directory?(File.join(path, '.git'))

        self.class.repository_url(remote_url(path))
        path
      end

      def remote_url(root, remote: 'origin')
        output = capture!(['git', 'remote', 'get-url', remote.to_s], chdir: root).strip
        self.class.repository_url(output)
      end

      def postprocess_clone(root)
        mprs = validate_mprs!(root)
        raise TeamServerError, 'clone contains no MPR' if mprs.empty?

        mprs
      end

      def validate_mprs!(root)
        Dir.glob(File.join(root, '*.mpr')).sort.map do |mpr|
          result = Mxrb.validate(mpr)
          raise TeamServerError, "cloned MPR is invalid: #{result.errors.first}" unless result.valid?

          mpr
        end
      end
    end

    # Read-only client for Mendix's official App Repository API.
    class Api
      def initialize(credentials: Credentials.new, client: OfficialMarketplace::HttpClient.new)
        @credentials = credentials
        @client = client
      end

      def info(app_id) = request("/repositories/#{id(app_id)}/info")

      def branches(app_id, limit: 100, cursor: nil)
        request("/repositories/#{id(app_id)}/branches", limit:, cursor:)
      end

      def branch(app_id, name)
        request("/repositories/#{id(app_id)}/branches/#{escape(name)}")
      end

      def commits(app_id, name, limit: 100, cursor: nil)
        request("/repositories/#{id(app_id)}/branches/#{escape(name)}/commits", limit:, cursor:)
      end

      private

      def request(path, parameters = {})
        token = @credentials.pat.to_s.strip
        if token.empty?
          raise TeamServerError,
                'Team Server API requires --pat-file or MXRB_TEAM_SERVER_PAT_FILE'
        end
        query = URI.encode_www_form(parameters.compact)
        url = query.empty? ? "#{API_BASE}#{path}" : "#{API_BASE}#{path}?#{query}"
        @client.json(url, authorization: "MxToken #{token}")
      rescue MarketplaceError => e
        raise TeamServerError, e.message
      end

      def id(value)
        identifier = value.to_s
        raise TeamServerError, 'invalid Team Server app ID' unless identifier.match?(APP_ID)

        identifier
      end

      def escape(value)
        URI.encode_www_form_component(value.to_s).gsub('+', '%20')
      end
    end

    # Read-only paginated client for Mendix's official Projects API.
    class ProjectsApi
      BASE = 'https://projects-api.home.mendix.com/v2/projects?limit=100'
      HOST = 'projects-api.home.mendix.com'
      MAX_PAGES = 100

      def initialize(credentials: Credentials.new, client: OfficialMarketplace::HttpClient.new)
        @credentials = credentials
        @client = client
      end

      def all
        projects = []
        each_page { projects.concat(Array(_1['items'])) }
        projects.freeze
      rescue MarketplaceError => e
        raise TeamServerError, e.message
      end

      private

      def each_page
        url = BASE
        MAX_PAGES.times do
          payload = @client.json(valid_url(url), authorization: authorization)
          yield payload
          url = payload.dig('links', 'next')
          return unless url
        end
        raise TeamServerError, 'Projects API pagination exceeded its safety limit'
      end

      def authorization
        token = @credentials.pat.to_s.strip
        raise TeamServerError, 'Projects API requires --pat-file or MXRB_TEAM_SERVER_PAT_FILE' if token.empty?

        "MxToken #{token}"
      end

      def valid_url(value)
        uri = URI.parse(value.to_s)
        path = %r{\A/v2/(?:projects|accounts/[^/]+/projects)\z}
        unless uri.is_a?(URI::HTTPS) && uri.host == HOST && uri.path.match?(path)
          raise TeamServerError, "unsafe Projects API pagination URL #{value.inspect}"
        end

        uri.to_s
      rescue URI::InvalidURIError
        raise TeamServerError, "unsafe Projects API pagination URL #{value.inspect}"
      end
    end
  end
end
