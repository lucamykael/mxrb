# frozen_string_literal: true

require 'mxrb'

module LegacyOqlViewFixture
  QUERY = 'SELECT Name AS Name FROM App.Item'

  def self.build(path, version: '10.24.18.103793') # rubocop:disable Metrics/MethodLength
    query = QUERY
    Mxrb.define(path) do
      mendix_version version
      self.module(:App) do
        entity(:Item) do
          string :Name
          string :Code
        end
        entity(:ItemView) do
          string :Name
          oql_view query: query
        end
        page(:Home) { title 'OQL storage' }
      end
      navigation { profile :Responsive, home_page: 'App.Home' }
    end
  end
end

LegacyOqlViewFixture.build(ARGV.fetch(0)) if $PROGRAM_NAME == __FILE__
