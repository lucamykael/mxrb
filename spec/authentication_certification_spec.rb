# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/AbcSize, Metrics/BlockLength, Metrics/MethodLength
RSpec.describe 'authentication document certification' do
  after { Mxrb::RubyApp::Registry.reset! }

  it 'keeps basic and OAuth2 authentication documents semantic for two Ruby cycles' do
    Dir.mktmpdir('mxrb-authentication-certification-') do |directory|
      current = File.join(directory, 'source.mpr')
      build_project(current)
      baseline = authentication_units(current)

      2.times do |index|
        exported = File.join(directory, "ruby-#{index}")
        rebuilt = File.join(directory, "rebuilt-#{index}.mpr")
        Mxrb::Exporter.new(current, exported).export!
        source = Dir[File.join(exported, '**', '*.rb')].sort.map { File.read(_1) }.join("\n")
        expect(source).to include(
          'authentication :BasicAuth', 'type: :basic',
          'authentication :ServiceOAuth', 'type: :oauth2_client_credentials',
          'authentication :UserOAuth', 'type: :oauth2_authorization_code'
        )
        expect(source).not_to include('native_document :BasicAuth', 'native_document :ServiceOAuth')

        generate(exported, rebuilt)
        expect(Mxrb.validate(rebuilt)).to be_valid
        expect(Mxrb.compare(current, rebuilt)).to be_identical
        expect(authentication_units(rebuilt)).to eq(baseline)
        current = rebuilt
      end
    end
  end

  it 'rejects unsupported declarations and falls back for unknown native shapes' do
    mod = Mxrb::Dsl::ModuleBuilder.new(:Auth)
    expect { mod.authentication(:Invalid, type: :digest) }
      .to raise_error(ArgumentError, /unsupported authentication type/)
    expect { mod.authentication(:Basic, type: :basic, username: 'Auth.User') }
      .to raise_error(ArgumentError, /requires username and password/)
    expect do
      mod.authentication(:OAuth, type: :oauth2_client_credentials, client_id: 'Auth.ClientId')
    end.to raise_error(ArgumentError, /tenant_id.*client_secret.*token_endpoint/)
    expect do
      mod.authentication(
        :OAuthCode, type: :oauth2_authorization_code, tenant_id: 'Auth.TenantId',
                    client_id: 'Auth.ClientId', client_secret: 'Auth.ClientSecret',
                    token_endpoint: 'Auth.TokenEndpoint'
      )
    end.to raise_error(ArgumentError, /authorization_endpoint.*callback_url/)

    exporter = Mxrb::Exporter.allocate
    document = {
      id: '11111111-1111-4111-8111-111111111111',
      container_id: '22222222-2222-4222-8222-222222222222', name: 'FutureAuth',
      type: 'Authentication$Authentication',
      doc: {
        '$ID' => '11111111-1111-4111-8111-111111111111',
        '$Type' => 'Authentication$Authentication', 'Name' => 'FutureAuth',
        'AuthenticationDetails' => {
          '$ID' => '33333333-3333-4333-8333-333333333333',
          '$Type' => 'Authentication$OAuth20ClientCredentialsDetails',
          'GrantType' => 'FutureGrant', 'Scopes' => [1]
        }
      }, containment: 'Documents'
    }
    declaration = exporter.send(:integration_document_declaration, document)
    expect(declaration).to include('native_document :FutureAuth', 'deep_structure:')

    base = document.fetch(:doc)
    variants = [
      base.merge('FutureField' => true),
      base.merge('AuthenticationDetails' => nil),
      base.merge('AuthenticationDetails' => base.fetch('AuthenticationDetails').merge('FutureField' => true)),
      base.merge('AuthenticationDetails' => base.fetch('AuthenticationDetails').except('Scopes'))
    ]
    variants.each { expect(exporter.send(:semantic_authentication?, _1)).to be(false) }
  end

  def build_project(path)
    Mxrb.define(path) do
      mendix_version '11.12.1'
      self.module :Auth do
        constant :User, type: :string, value: 'api-user'
        constant :Password, type: :string, value: 'api-password'
        constant :ClientId, type: :string, value: 'client-id'
        constant :ClientSecret, type: :string, value: 'client-secret'
        constant :TenantId, type: :string, value: 'tenant'
        constant :TokenEndpoint, type: :string, value: 'https://identity.example/oauth/token'
        constant :AuthorizationEndpoint, type: :string,
                                         value: 'https://identity.example/oauth/authorize'
        constant :CallbackUrl, type: :string, value: 'https://app.example/oauth/callback'
        authentication :BasicAuth, type: :basic,
                                   username: 'Auth.User', password: 'Auth.Password'
        authentication :ServiceOAuth, type: :oauth2_client_credentials,
                                      provider_name: 'Identity',
                                      well_known_endpoint: 'https://identity.example/.well-known/openid-configuration',
                                      tenant_id: 'Auth.TenantId', client_id: 'Auth.ClientId',
                                      client_secret: 'Auth.ClientSecret',
                                      token_endpoint: 'Auth.TokenEndpoint',
                                      scopes: %w[read write], audience: 'api'
        authentication :UserOAuth, type: :oauth2_authorization_code,
                                   provider_name: 'Identity', tenant_id: 'Auth.TenantId',
                                   client_id: 'Auth.ClientId',
                                   client_secret: 'Auth.ClientSecret',
                                   authorization_endpoint: 'Auth.AuthorizationEndpoint',
                                   token_endpoint: 'Auth.TokenEndpoint', callback_url: 'Auth.CallbackUrl',
                                   scopes: %w[openid profile]
        page(:Home) { title 'Authentication certification' }
      end
      navigation do
        profile :Responsive, home_page: 'Auth.Home', app_title: 'Authentication certification'
      end
    end
  end

  def authentication_units(path)
    Mxrb.open(path) do |project|
      project.all_units.filter_map do |unit|
        doc = project.parse_bson(unit)
        next unless doc['$Type'] == 'Authentication$Authentication'

        details_id = Mxrb::IO::BsonCodec.extract_id(doc.dig('AuthenticationDetails', '$ID'))
        [doc['Name'], unit['UnitID'].to_s, details_id.to_s]
      end.sort
    end
  end

  def generate(exported, rebuilt)
    previous = ENV['MXRB_OUTPUT_PATH']
    ENV['MXRB_OUTPUT_PATH'] = rebuilt
    load File.join(exported, 'project.rb')
  ensure
    previous ? ENV['MXRB_OUTPUT_PATH'] = previous : ENV.delete('MXRB_OUTPUT_PATH')
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/BlockLength, Metrics/MethodLength
