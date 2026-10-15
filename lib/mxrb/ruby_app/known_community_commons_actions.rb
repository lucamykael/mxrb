# frozen_string_literal: true

require 'base64'
require 'digest'
require 'securerandom'

module Mxrb
  module RubyApp
    # Actions of the Marketplace CommunityCommons module. An action is enabled only
    # when its source and the helper classes it calls are the bytes of an audited
    # release; behaviour that differs between releases is keyed by that release.
    # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength
    # rubocop:disable Metrics/ModuleLength, Metrics/PerceivedComplexity
    module KnownCommunityCommonsActions
      RELEASES = {
        '9.0.1' => {
          'StringUtils' => 'cfa3984888e0664ef4f11a15240c0b21ef70a92416390231c9a4082afc58d7bc',
          'Misc' => 'ba07907b457a8b651debea5a92dfa1534a61d7b9a57716fa76a9149482c07a98',
          'Base64Encode' => '312c5203f10558bc21304a7133d6bf8593323c1ff18ed283dba9c685e9cdd774',
          'EndTransaction' => 'f1e705c385d1848022a7db7d818a9bdab9088b04733443f4bc9c989034d3f6d9',
          'GetApplicationUrl' => '24d846168bfa8f8ab8dccfaae4fdb87c05a2a9c452ffefbbb7e8be9d62c434be',
          'RandomHash' => 'd5790c9548f7b835fe0e43c8b8d86c4c00223fe92ae9d470e51d89f9e42a5fbc',
          'RandomString' => '569861dad53738473fb197a63af7f038481b9f95ad6d47adb89c0bc28c0de54d',
          'RandomStrongPassword' => '25e8b6e2638238d6b1f8c1b600d85ce5db34033b7d1f02490f8b16d710d1fa16',
          'StringFromFile' => 'f4e7913254fc327bf32426296c004da56708bce682e65f780ee8ec93f69b62ce',
          'StringLeftPad' => 'f3033dc1953f9d66b2b0326aeb43184a152f978affd35e6aca2e78e0f44b14ea',
          'StringSplit' => '1426f9d82a1508c5d137d8605be8aab34bd0468a9e7c55cc102a8ba260a1390c',
          'ThrowException' => 'd532e88dec814b5ce3e35b28a24211b27bebd90e1de8770c8d3d0cd5e6456571'
        },
        '11.5.1' => {
          'StringUtils' => '5ade176f60cba27693a59638df1328bf85248511fb07d9cc0de70f3c8c89b1db',
          'Misc' => '2e1b8b14316ac39dcf79623a8ddc595527dfe171d11912a6cc30453b5f900f86',
          'Logging' => 'a7d0bca7aabe8ac4586e7f73788fa7b0d79e6ed6173f21dea0494b3bb7c55a74',
          'ORM' => '3fe250327157cd1ab141327db84cfd7793ed0371131e2a4e6ddf56486e950666',
          'Base64Encode' => '773c02051230e62828baf082e6d626514fae019a6ec7d49e599ad6f1f9a49086',
          'EndTransaction' => '7f5bee3a1d3ea6e938eff42a27f95e4b02f69378ac1e0e4463bf244db7355b81',
          'GetApplicationUrl' => '9a02e5825c37bb499adfe98c9032d9c77b9e043ee3b0aabea22502c84746282e',
          'GetModelVersion' => 'c348fa8d9dc345a472496eab44d18948f32963c4dd9ac42ae4a953bb0a69d9bc',
          'GetRuntimeVersion' => '31f994daa04d1c04edf0a7b97f437c23ffbac5963fd1c75e94c16ab6e1baca4b',
          'Hash' => '917f49a5102ed203fb424f0453543de29121c2edb7551f6fc69021d75429ca0d',
          'RandomHash' => 'ef5593cfbb1392279ad06b272be4a054c2059c761033c8adb8cf8a0d5b5dc455',
          'RandomString' => '9e78248c38a5ab004a117fd1ca32cfc8eb8d7d32ee7b572672fafafbae330f25',
          'RandomStrongPassword' => '0f80ae4a83e543f24fa63d20d989e50c8844d66315b93c63b6ed2b8e6fe14c47',
          'StringFromFile' => '7e571ea53dfdc6462ca2018bc13cf0bb26ee6e4e28d3b23876a8a07f0299bdc6',
          'StringLeftPad' => 'ceb3b6ae923475b25af658bb67188ca2fd375d030958ac2c1ed50639a99e38b0',
          'StringSplit' => 'fa3d3e05a8680a6324c8f19498707b9fad0d35d862c314c4c420ade485b24869',
          'StringTrim' => '66affd74e82ff0ac344636df736bac7c04fada31c9274adccff9f5755c8ccd14',
          'ThrowException' => '432bb1b73bffe82bfd910ae83ac55c593c065b07cdee00728b76e7928f28d3ba',
          'TimeMeasureEnd' => '351f24e974f5d78f94c1149d6dc92dcfae6d49bc6fd25bb172c060f5482546d9',
          'TimeMeasureStart' => '05995562fe82f9ee6c68cf25e0a9007d331d99a97a33732b19f7c21b45a68b3d',
          'copyAttributes' => '466ab2ef685931491817f3dbef308d90e782368fc9ecbb940809124c547d618e',
          'executeUnverifiedMicroflowAsUser_2' => 'c7e367f0169ca046137f9062d7bef5765ee0dc83eb1ef31e579e7e17c3824df5',
          'objectHasChanged' => '48c1eccdc584130c7c1f823f096f268cb16de5326226dd1bb93c8e93101cba3f'
        }
      }.freeze
      # The communitycommons helper classes each action calls.
      HELPERS = {
        'Base64Encode' => %w[StringUtils], 'GetApplicationUrl' => %w[Misc], 'Hash' => %w[StringUtils],
        'RandomHash' => %w[StringUtils], 'RandomString' => %w[StringUtils], 'RandomStrongPassword' => %w[StringUtils],
        'StringFromFile' => %w[StringUtils], 'StringLeftPad' => %w[StringUtils], 'ThrowException' => %w[Misc],
        'TimeMeasureEnd' => %w[Logging], 'TimeMeasureStart' => %w[Logging], 'copyAttributes' => %w[ORM],
        'executeUnverifiedMicroflowAsUser_2' => %w[Misc], 'objectHasChanged' => %w[ORM]
      }.freeze
      ACTIONS = {
        'Base64Encode' => :base64_encode, 'EndTransaction' => :end_transaction,
        'GetApplicationUrl' => :application_url, 'GetModelVersion' => :model_version,
        'GetRuntimeVersion' => :runtime_version, 'Hash' => :sha256, 'RandomHash' => :random_hash,
        'RandomString' => :random_string, 'RandomStrongPassword' => :random_strong_password,
        'StringFromFile' => :string_from_file, 'StringLeftPad' => :left_pad, 'StringSplit' => :split,
        'StringTrim' => :trim, 'ThrowException' => :throw_exception, 'TimeMeasureEnd' => :measure_end,
        'TimeMeasureStart' => :measure_start, 'copyAttributes' => :copy_attributes,
        'executeUnverifiedMicroflowAsUser_2' => :execute_microflow_as_user, 'objectHasChanged' => :changed
      }.freeze
      UPPERCASE = ('A'..'Z').to_a.freeze
      LOWERCASE = ('a'..'z').to_a.freeze
      DIGITS = ('0'..'9').to_a.freeze
      SPECIAL = ('!'..'/').to_a.freeze
      ALPHANUMERIC = (UPPERCASE + LOWERCASE + DIGITS).freeze
      INT = (-(2**31)..((2**31) - 1))
      ENCODINGS = %w[US_ASCII ISO_8859_1 UTF_8 UTF_16BE UTF_16LE UTF_16].freeze
      UTF8_BOM = "\xEF\xBB\xBF".b.freeze
      PASSWORD_PARTS = { '9.0.1' => '(CAPS, DIGITS, SPL CHARS)', '11.5.1' => '(CAPS, LOWER, DIGITS, SPL CHARS)' }.freeze
      TIMERS = {} # rubocop:disable Style/MutableConstant
      TIMERS_LOCK = Mutex.new

      module_function

      def registrations(directory)
        root = File.join(directory, 'javasource', 'communitycommons')
        ACTIONS.keys.filter_map do |name|
          release = RELEASES.find { |_, sources| audited?(root, name, sources) }&.first
          "Mxrb::RubyApp::KnownCommunityCommonsActions.register(#{name.inspect}, #{release.inspect})" if release
        end.join("\n")
      end

      def audited?(root, name, sources)
        files = HELPERS.fetch(name, []).to_h { [File.join(root, "#{_1}.java"), sources[_1]] }
        files[File.join(root, 'actions', "#{name}.java")] = sources[name]
        files.all? do |path, hash|
          hash && File.file?(path) && Digest::SHA256.hexdigest(File.binread(path).gsub("\r\n", "\n")) == hash
        end
      end

      def register(name, release)
        raise KeyError, "CommunityCommons #{release} #{name} is not audited" unless RELEASES.fetch(release).key?(name)

        action = method(ACTIONS.fetch(name))
        Registry.register_java_custom_action("CommunityCommons.#{name}", with_context: true) do |arguments, context:|
          action.call(arguments, context, release)
        end
      end

      def java_error(java_class, message) = raise(Runtime::JavaActionError.new(java_class, message))
      def illegal_argument(message) = java_error('java.lang.IllegalArgumentException', message)
      def null_pointer(name) = java_error('java.lang.NullPointerException', "#{name} is null")

      def base64_encode(arguments, _context, _release)
        value = arguments['value']
        value.nil? ? nil : Base64.strict_encode64(value.encode('UTF-8'))
      end

      def end_transaction(_arguments, context, _release)
        context.end_transaction
        true
      end

      def application_url(_arguments, context, _release) = context.application_root_url.delete_suffix('/')
      def model_version(_arguments, context, _release) = context.model_version
      def runtime_version(_arguments, context, _release) = context.runtime_version

      # StringUtils.hash ignores the length parameter: always the hex SHA-256.
      def sha256(arguments, _context, _release)
        value = arguments['value']
        null_pointer('value') if value.nil?
        Digest::SHA256.hexdigest(value.encode('UTF-8'))
      end

      def random_hash(_arguments, _context, _release) = SecureRandom.uuid

      def random_string(arguments, _context, _release)
        length = arguments['length']
        null_pointer('length') if length.nil?
        random_characters(java_int(length), ALPHANUMERIC)
      end

      def random_strong_password(arguments, _context, release)
        minimum, maximum, capitals, digits, specials =
          %w[MinLength MaxLength NrOfCapitalizedCharacters NrOfDigits NrOfSpecialCharacters].map do |name|
            value = arguments[name]
            null_pointer(name) if value.nil? && release == '9.0.1'
            safe_int(value.to_i)
          end
        illegal_argument('Min. Length > Max. Length!') if minimum > maximum
        fixed = capitals + digits + specials
        if fixed > minimum
          illegal_argument("Min. Length should be atleast sum of #{PASSWORD_PARTS.fetch(release)} Length!")
        end

        rest = random_characters(minimum - fixed + SecureRandom.random_number(maximum - minimum + 1), ALPHANUMERIC)
        (random_characters(capitals, UPPERCASE) + random_characters(digits, DIGITS) +
          random_characters(specials, SPECIAL) + rest).chars.shuffle(random: SecureRandom).join
      end

      def string_from_file(arguments, context, release)
        source = arguments['source']
        return nil if source.nil?

        key = arguments['encoding'].to_s.split('.').last.to_s
        encoding = key.empty? ? 'UTF_8' : key
        illegal_argument("unknown encoding #{encoding}") unless ENCODINGS.include?(encoding)
        bytes = context.file_content(source)
        bytes = bytes.delete_prefix(UTF8_BOM) unless release == '9.0.1'
        encoding, bytes = utf16(bytes) if encoding == 'UTF_16'
        bytes.dup.force_encoding(encoding.tr('_', '-'))
             .encode('UTF-8', invalid: :replace, undef: :replace, replace: "\uFFFD")
      end

      # Java's UTF-16 decoder reads a byte order mark and defaults to big-endian.
      def utf16(bytes)
        return ['UTF_16LE', bytes.byteslice(2..)] if bytes.start_with?("\xFF\xFE".b)

        ['UTF_16BE', bytes.start_with?("\xFE\xFF".b) ? bytes.byteslice(2..) : bytes]
      end

      # org.apache.commons.lang3.StringUtils.leftPad, which the action calls.
      def left_pad(arguments, _context, _release)
        value = arguments['value']
        return nil if value.nil?

        amount = arguments['amount']
        null_pointer('amount') if amount.nil?
        fill = arguments['fillCharacter'].to_s
        fill = ' ' if fill.empty?
        pads = java_int(amount) - value.length
        return value if pads <= 0

        (fill * ((pads / fill.length) + 1))[0, pads] + value
      end

      # String.split(regex): no match keeps the input, trailing empty parts are removed.
      def split(arguments, context, _release)
        input = arguments['inputString']
        pattern = arguments['splitParameter']
        null_pointer('inputString') if input.nil?
        null_pointer('splitParameter') if pattern.nil?
        java_split(input, Regexp.new(pattern)).each_with_index.map do |part, index|
          context.store.create('CommunityCommons.SplitItem').tap do |item|
            item.members.merge!('Value' => part, 'Index' => index)
          end
        end
      end

      def trim(arguments, _context, _release)
        value = arguments['value']
        value.nil? ? '' : value.sub(/\A[\u0000- ]+/, '').sub(/[\u0000- ]+\z/, '')
      end

      def throw_exception(arguments, _context, _release)
        java_error('communitycommons.UserThrownException', arguments['message'])
      end

      def measure_start(arguments, _context, _release)
        TIMERS_LOCK.synchronize { TIMERS[arguments['TimerName']] = now }
        true
      end

      def measure_end(arguments, context, _release)
        name = arguments['TimerName']
        started = TIMERS_LOCK.synchronize { TIMERS[name] }
        illegal_argument(format('Timer with key %s not found', name.nil? ? 'null' : name)) unless started
        level = arguments['Loglevel'].to_s.split('.').last
        null_pointer('Loglevel') if level.nil?
        taken = now - started
        message = arguments['message']
        context.log('CommunityCommons', level,
                    "Timer #{name} finished in #{taken} ms. #{message.nil? ? 'null' : message}")
        taken
      end

      def copy_attributes(arguments, context, _release)
        source = arguments['source']
        target = arguments['target']
        java_error('java.lang.IllegalStateException', 'source is null') if source.nil?
        java_error('java.lang.IllegalStateException', 'target is null') if target.nil?
        source_names = context.attributes(source.entity).map(&:first)
        context.attributes(target.entity).each do |name, type, calculated|
          next if calculated || type == :autonumber || !source_names.include?(name)

          target.members[name] = source.members[name]
        end
        context.store.touch(target) if context.store.respond_to?(:touch)
        true
      end

      def execute_microflow_as_user(arguments, context, _release)
        name = arguments['microflowName'].to_s
        java_error('java.lang.Exception', 'Assertion: No context provided') if name.empty?
        java_error('java.lang.Exception', "Assertion: microflow not found: #{name}") unless context.flow?(name)
        username = arguments['username'].to_s
        java_error('java.lang.RuntimeException', 'Assertion: No username provided') if username.empty?

        parameters = [%w[arg1name arg1value], %w[arg2name arg2value]].each_with_object({}) do |(key, value), result|
          result[arguments[key].to_s] = arguments[value] unless arguments[key].nil?
        end
        result = context.call_flow(name, parameters, username:, sudo: arguments['sudoContext'] == true)
        result&.to_s
      end

      def changed(arguments, context, _release)
        item = arguments['item']
        illegal_argument('The provided object is empty') if item.nil?
        context.changed?(item)
      end

      def random_characters(count, characters)
        illegal_argument("The requested length for the random string was negative: #{count}") if count.negative?

        Array.new(count) { characters[SecureRandom.random_number(characters.length)] }.join
      end

      def java_int(value)
        value = value.to_i
        (value + (2**31)) % (2**32) - (2**31)
      end

      def safe_int(value)
        illegal_argument("#{value} cannot be cast to int without changing its value.") unless INT.cover?(value)

        value
      end

      def java_split(input, regexp)
        parts = []
        start = 0
        matched = false
        input.scan(regexp) do
          match = Regexp.last_match
          next if match.end(0).zero?

          matched = true
          parts << input[start...match.begin(0)]
          start = match.end(0)
        end
        return [input] unless matched

        parts << input[start..]
        parts.pop while parts.last == ''
        parts
      end

      def now = Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond)
    end
    # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength
    # rubocop:enable Metrics/ModuleLength, Metrics/PerceivedComplexity
  end
end
