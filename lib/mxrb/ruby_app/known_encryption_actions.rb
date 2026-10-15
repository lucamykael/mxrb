# frozen_string_literal: true

require 'base64'
require 'digest'
require 'openssl'

module Mxrb
  module RubyApp
    # EncryptString and DecryptString of the Marketplace Encryption module, enabled
    # only for the audited sources. Strings are AES/GCM ({AES3}), or legacy AES/CBC
    # ({AES}); {AES2} needs a cipher the 11.12.1 Runtime only gains once the module's
    # PGP actions have registered BouncyCastle, so it fails as on a fresh Runtime.
    # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/ModuleLength
    module KnownEncryptionActions
      RELEASES = {
        '8.0.2' => {
          'EncryptString' => 'b91e6aed61257793a46a9abc2eed695e977e1700a4d80ae72867dc992cbfd90c',
          'DecryptString' => '917adb8e46a4c148b4c93fc541553da11224275205ddb9c0d172d580036cad10'
        },
        '10.0.2' => {
          'EncryptString' => 'ff3e6b82d1e0f760b9844a95ffe81c23a941dfdcae31a39c36b1562139628def',
          'DecryptString' => '4cdc57d43875ace49e54e803642d533bb18770699f666487417e9d934ea417d8'
        }
      }.freeze
      NEW_PREFIX = '{AES3}'
      LEGACY_PREFIX = /\A\{AES2?\}\z/
      # Pattern "^\{([a-zA-Z0-9]*)\}.*$": the dot stops at a Java line terminator.
      PREFIX = /\A\{([a-zA-Z0-9]*)\}[^\n\r\u0085  ]*(?:\r\n|[\n\r\u0085  ])?\z/
      MENDIX_ERROR = 'com.mendix.systemwideinterfaces.MendixRuntimeException'
      WRONG_KEY = 'Cannot decrypt the text because it was either encrypted with a different key or not encrypted at all'
      TAG_LENGTH = 16

      module_function

      def registrations(directory)
        root = File.join(directory, 'javasource', 'encryption', 'actions')
        RELEASES.values.flat_map(&:keys).uniq.filter_map do |name|
          path = File.join(root, "#{name}.java")
          next unless File.file?(path)

          digest = Digest::SHA256.hexdigest(File.binread(path).gsub("\r\n", "\n"))
          release = RELEASES.find { |_, sources| sources[name] == digest }&.first
          "Mxrb::RubyApp::KnownEncryptionActions.register(#{name.inspect}, #{release.inspect})" if release
        end.join("\n")
      end

      def register(name, release)
        raise KeyError, "Encryption #{release} #{name} is not audited" unless RELEASES.fetch(release).key?(name)

        Registry.register_java_custom_action("Encryption.#{name}",
                                             method(name == 'EncryptString' ? :encrypt : :decrypt))
      end

      def java_error(java_class, message) = raise(Runtime::JavaActionError.new(java_class, message))
      def mendix_error(message) = java_error(MENDIX_ERROR, message)

      def encrypt(arguments)
        value, key, prefix = arguments.values_at('value', 'key', 'prefix')
        return nil if value.nil?

        mendix_error('Prefix should not be empty') if prefix.to_s.empty?
        if LEGACY_PREFIX.match?(prefix)
          mendix_error("The used prefix is no longer supported for encryption. Please use '#{NEW_PREFIX}'.")
        end
        mendix_error("Invalid prefix used. Please use '#{NEW_PREFIX}'.") unless prefix == NEW_PREFIX
        check_key(key, 'Key', 32)
        cipher = aes(key, 'gcm').encrypt
        cipher.key = key.b
        iv = cipher.random_iv
        data = cipher.update(value.encode('UTF-8')) + cipher.final + cipher.auth_tag(TAG_LENGTH)
        "#{prefix}#{Base64.strict_encode64(iv)};#{Base64.strict_encode64(data)}"
      end

      def decrypt(arguments)
        value, key, prefix, legacy_key = arguments.values_at('value', 'key', 'prefix', 'legacyKey')
        unless prefix.nil?
          mendix_error('Prefix should be null when passed to DecryptString, this parameter will be deprecated')
        end
        return nil if value.nil?

        text_prefix = PREFIX.match(value)&.[](1)
        mendix_error('Encrypted string does not have a valid prefix.') if text_prefix.nil?
        case text_prefix
        when 'AES' then decrypt_cbc(value, legacy_key)
        when 'AES2' then decrypt_gcm_padded(value, legacy_key)
        when 'AES3' then decrypt_gcm(value, key)
        else mendix_error("Invalid prefix encountered when trying to decrypt string: {#{text_prefix}}")
        end
      end

      def decrypt_gcm(value, key)
        check_key(key, 'Key', 32)
        iv, data = parts(value, NEW_PREFIX, 'Unexpected prefix when trying to decrypt string.')
        cipher = aes(key, 'gcm').decrypt
        java_error('java.security.InvalidAlgorithmParameterException', 'IV is empty') if iv.empty?
        cipher.key = key.b
        if data.bytesize < TAG_LENGTH
          java_error('javax.crypto.AEADBadTagException',
                     "Input data too short to contain an expected tag length of #{TAG_LENGTH}bytes")
        end
        cipher.iv_len = iv.bytesize
        cipher.iv = iv
        cipher.auth_tag = data.byteslice(-TAG_LENGTH, TAG_LENGTH)
        text(cipher.update(data.byteslice(0, data.bytesize - TAG_LENGTH)) + cipher.final)
      rescue OpenSSL::Cipher::CipherError
        mendix_error(WRONG_KEY)
      end

      def decrypt_gcm_padded(value, legacy_key)
        check_key(legacy_key, 'Legacy key', 16)
        parts(value, '{AES2}', 'Unexpected prefix when trying to decrypt string using legacy algorithm.')
        java_error('java.security.NoSuchAlgorithmException', 'Cannot find any provider supporting AES/GCM/PKCS5PADDING')
      end

      def decrypt_cbc(value, legacy_key)
        check_key(legacy_key, 'Legacy key', 16)
        iv, data = parts(value, '{AES}', 'Unexpected prefix when trying to decrypt string using legacy algorithm.')
        cipher = aes(legacy_key, 'cbc').decrypt
        mendix_error(WRONG_KEY) unless iv.bytesize == 16
        cipher.key = legacy_key.b
        unless (data.bytesize % 16).zero?
          java_error('javax.crypto.IllegalBlockSizeException',
                     'Input length must be multiple of 16 when decrypting with padded cipher')
        end
        cipher.iv = iv
        text(cipher.update(data) + cipher.final)
      rescue OpenSSL::Cipher::CipherError
        mendix_error(WRONG_KEY)
      end

      # The Java key length check counts UTF-16 units; the cipher then needs 16, 24 or 32 bytes.
      def check_key(key, label, length)
        mendix_error("#{label} should not be empty") if key.to_s.empty?
        mendix_error("#{label} length should be #{length}") unless key.encode('UTF-16LE').bytesize / 2 == length
      end

      def aes(key, mode)
        bits = { 16 => 128, 24 => 192, 32 => 256 }[key.bytesize]
        java_error('java.security.InvalidKeyException', "Invalid AES key length: #{key.bytesize} bytes") unless bits
        OpenSSL::Cipher.new("aes-#{bits}-#{mode}")
      end

      # String.split(";") then Base64 decoding of the IV and the data.
      def parts(value, prefix, message)
        pieces = value.byteslice(prefix.bytesize..).split(';')
        mendix_error(message) if pieces.length < 2

        pieces.first(2).map { decode(_1) }
      end

      def decode(text)
        illegal = text.each_char.find { !_1.match?(%r{[A-Za-z0-9+/=]}) }
        java_error('java.lang.IllegalArgumentException', format('Illegal base64 character %x', illegal.ord)) if illegal

        Base64.decode64(text)
      end

      def text(bytes) = bytes.force_encoding('UTF-8').scrub("\uFFFD")
    end
    # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/ModuleLength
  end
end
