# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::RubyApp::KnownEncryptionActions do
  # Vectors written by the module's Java code on Java 21 (the 11.12.1 Runtime).
  let(:key) { '0123456789abcdef0123456789abcdef' }
  let(:legacy_key) { 'fedcba9876543210' }
  let(:gcm) { '{AES3}AQIDBAUGBwgJCgsM;YYTSjwCRiNln/n1g4jQFHOTW46ODV8gRnq4=' }
  let(:cbc) { '{AES}EA8ODQwLCgkIBwYFBAMCAQ==;8xB+8Il1RXLp+6wPLUfYgA==' }
  let(:mendix) { 'com.mendix.systemwideinterfaces.MendixRuntimeException' }
  let(:wrong_key) do
    'Cannot decrypt the text because it was either encrypted with a different key or not encrypted at all'
  end

  after { Mxrb::RubyApp::Registry.reset! }

  def java_error(java_class, message)
    raise_error(Mxrb::Runtime::JavaActionError) do |error|
      expect([error.java_class, error.message]).to eq([java_class, message])
    end
  end

  def decrypt(value, **options) = described_class.decrypt({ 'value' => value }.merge(options.transform_keys(&:to_s)))

  def encrypt(value, key: self.key, prefix: '{AES3}')
    described_class.encrypt('value' => value, 'key' => key, 'prefix' => prefix)
  end

  it 'registers the audited release of each action' do
    Dir.mktmpdir do |root|
      expect(described_class.registrations(root)).to eq('')
      actions = File.join(root, 'javasource', 'encryption', 'actions')
      FileUtils.mkdir_p(actions)
      File.write(File.join(actions, 'EncryptString.java'), "x\r\n")
      File.write(File.join(actions, 'DecryptString.java'), 'custom')
      stub_const("#{described_class}::RELEASES",
                 '1' => { 'EncryptString' => Digest::SHA256.hexdigest("x\n"), 'DecryptString' => 'other' })
      expect(described_class.registrations(root))
        .to eq('Mxrb::RubyApp::KnownEncryptionActions.register("EncryptString", "1")')
    end
  end

  it 'registers adapters that round-trip a string' do
    described_class.register('EncryptString', '10.0.2')
    described_class.register('DecryptString', '8.0.2')
    actions = Mxrb::RubyApp::Registry.java_custom_actions
    encrypted = actions.fetch('Encryption.EncryptString').call('value' => 'x', 'key' => key, 'prefix' => '{AES3}')
    expect(actions.fetch('Encryption.DecryptString').call('value' => encrypted, 'key' => key)).to eq('x')
    expect { described_class.register('PGPEncryptDocument', '10.0.2') }.to raise_error(KeyError, /not audited/)
  end

  it 'reads the strings Java encrypted and writes ones it reads back' do
    expect(decrypt(gcm, key:)).to eq('olá mundo')
    expect(decrypt(cbc, legacyKey: legacy_key)).to eq('segredo antigo')
    encrypted = encrypt('ida e volta')
    expect(encrypted).to match(%r{\A\{AES3\}[A-Za-z0-9+/]{16};[A-Za-z0-9+/=]+\z})
    expect(decrypt(encrypted, key:)).to eq('ida e volta')
    expect(encrypt(nil)).to be_nil
    expect(decrypt(nil)).to be_nil
  end

  it 'rejects prefixes and keys with the module messages' do
    expect { encrypt('x', prefix: '') }.to java_error(mendix, 'Prefix should not be empty')
    expect { encrypt('x', prefix: '{AES2}') }
      .to java_error(mendix, "The used prefix is no longer supported for encryption. Please use '{AES3}'.")
    expect { encrypt('x', prefix: '{RSA}') }.to java_error(mendix, "Invalid prefix used. Please use '{AES3}'.")
    expect { encrypt('x', key: nil) }.to java_error(mendix, 'Key should not be empty')
    expect { encrypt('x', key: 'short') }.to java_error(mendix, 'Key length should be 32')
    expect { encrypt('x', key: "#{'é' * 31}1") }
      .to java_error('java.security.InvalidKeyException', 'Invalid AES key length: 63 bytes')
    expect { decrypt(gcm, prefix: '{AES3}') }
      .to java_error(mendix, 'Prefix should be null when passed to DecryptString, this parameter will be deprecated')
    expect { decrypt('plain') }.to java_error(mendix, 'Encrypted string does not have a valid prefix.')
    expect { decrypt("{AES3}a;b\nc", key:) }.to java_error(mendix, 'Encrypted string does not have a valid prefix.')
    expect { decrypt('{DES}a;b') }
      .to java_error(mendix, 'Invalid prefix encountered when trying to decrypt string: {DES}')
    expect { decrypt(cbc) }.to java_error(mendix, 'Legacy key should not be empty')
    expect { decrypt(cbc, legacyKey: 'x') }.to java_error(mendix, 'Legacy key length should be 16')
  end

  it 'fails like the Java ciphers on damaged or foreign input' do
    expect { decrypt(gcm, key: key.reverse) }.to java_error(mendix, wrong_key)
    expect { decrypt(cbc, legacyKey: legacy_key.reverse) }.to java_error(mendix, wrong_key)
    expect { decrypt('{AES3}AQIDBAUGBwgJCgsM', key:) }
      .to java_error(mendix, 'Unexpected prefix when trying to decrypt string.')
    expect { decrypt('{AES}abc', legacyKey: legacy_key) }
      .to java_error(mendix, 'Unexpected prefix when trying to decrypt string using legacy algorithm.')
    expect { decrypt('{AES3}a-b;AA==', key:) }
      .to java_error('java.lang.IllegalArgumentException', 'Illegal base64 character 2d')
    expect { decrypt('{AES3};AAAA', key:) }
      .to java_error('java.security.InvalidAlgorithmParameterException', 'IV is empty')
    expect { decrypt('{AES3}AQIDBAUGBwgJCgsM;AAAA', key:) }
      .to java_error('javax.crypto.AEADBadTagException',
                     'Input data too short to contain an expected tag length of 16bytes')
    expect { decrypt('{AES}AAAA;AAAAAAAAAAAAAAAAAAAAAA==', legacyKey: legacy_key) }.to java_error(mendix, wrong_key)
    expect { decrypt('{AES}EA8ODQwLCgkIBwYFBAMCAQ==;AAAAAAA=', legacyKey: legacy_key) }
      .to java_error('javax.crypto.IllegalBlockSizeException',
                     'Input length must be multiple of 16 when decrypting with padded cipher')
    expect { decrypt('{AES2}AAAA;AAAA', legacyKey: legacy_key) }
      .to java_error('java.security.NoSuchAlgorithmException',
                     'Cannot find any provider supporting AES/GCM/PKCS5PADDING')
    expect { decrypt('{AES2}AAAA', legacyKey: legacy_key) }
      .to java_error(mendix, 'Unexpected prefix when trying to decrypt string using legacy algorithm.')
  end
end
# rubocop:enable Metrics/BlockLength
