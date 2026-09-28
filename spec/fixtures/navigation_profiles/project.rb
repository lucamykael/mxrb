# frozen_string_literal: true

require 'mxrb'

# rubocop:disable Metrics/AbcSize, Metrics/BlockLength, Metrics/MethodLength
# Builds the official-MxBuild witness for supported navigation profile fields.
module NavigationProfilesFixture
  VERSION = '11.12.1'

  module_function

  def build(destination)
    Mxrb.define(destination) do
      mendix_version VERSION
      self.module :NavigationProfiles do
        module_role :User
        page :Home do
          title 'Navigation profiles'
          allowed_roles 'NavigationProfiles.User'
        end
        page :Login do
          title 'Sign in'
          allowed_roles 'NavigationProfiles.User'
        end
        page :NotFound do
          title 'Not found'
          allowed_roles 'NavigationProfiles.User'
        end
        microflow(:OpenHome) do
          allowed_roles 'NavigationProfiles.User'
          show_page 'NavigationProfiles.Home'
        end
      end
      security do
        security_level :CheckEverything
        user_role :User, module_roles: ['NavigationProfiles.User']
      end
      navigation do
        profile :Responsive,
                home_page: 'NavigationProfiles.Home',
                sign_in_page: 'NavigationProfiles.Login',
                sign_in_title: { en_US: 'Sign in', pt_BR: 'Entrar' },
                not_found_page: 'NavigationProfiles.NotFound',
                app_title: 'Navigation profiles',
                throw_partial_sync_error: false do
          home_for :User, microflow: 'NavigationProfiles.OpenHome'
          item 'Home', page: 'NavigationProfiles.Home', icon: :home
        end
      end
    end
  end
end

NavigationProfilesFixture.build(ARGV.fetch(0)) if $PROGRAM_NAME == __FILE__
# rubocop:enable Metrics/AbcSize, Metrics/BlockLength, Metrics/MethodLength
