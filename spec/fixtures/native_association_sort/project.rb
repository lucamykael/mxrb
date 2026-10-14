# frozen_string_literal: true

require 'mxrb'

# Headless native oracle for retrieve sorting over associations; run with
# script/oql_native_oracle. Each case logs "ORACLE <name>=<names in order>".
CASES = {
  'RegionName' => [['Views.Shop_Region/Views.Region/Name', 'Ascending'], ['Views.Shop.Name', 'Ascending']],
  'RegionDesc' => [['Views.Shop_Region/Views.Region/Name', 'Descending'], ['Views.Shop.Name', 'Ascending']],
  'CountryRank' => [['Views.Shop_Region/Views.Region/Views.Region_Country/Views.Country/Rank', 'Ascending'],
                    ['Views.Shop.Name', 'Ascending']]
}.freeze
# rubocop:disable Metrics/BlockLength
Mxrb.define(ENV.fetch('MXRB_OUTPUT_PATH')) do
  mendix_version '11.12.1'
  self.module :Views do
    entity(:Country) do
      string :Name
      integer :Rank
    end
    entity(:Region) do
      string :Name
      association 'Views.Country', name: 'Region_Country', cardinality: :many_to_one
    end
    entity(:Shop) do
      string :Name
      association 'Views.Region', name: 'Shop_Region', cardinality: :many_to_one
    end
    microflow :Seed do
      create_object 'Views.Country', as: :brazil, commit: true, set: { Name: "'Brazil'", Rank: '2' }
      create_object 'Views.Country', as: :chile, commit: true, set: { Name: "'Chile'", Rank: '1' }
      [%w[north North brazil], %w[south South chile], %w[east East brazil]].each do |variable, name, country|
        create_object 'Views.Region', as: variable, commit: true do
          set :Name, to: "'#{name}'"
          set_association 'Views.Region_Country', to: "$#{country}"
        end
      end
      [%w[Anna south], %w[Bea north], %w[Caio east], %w[Dora south], ['Eli', nil]].each do |name, region|
        create_object 'Views.Shop', as: "shop#{name}", commit: true do
          set :Name, to: "'#{name}'"
          set_association 'Views.Shop_Region', to: "$#{region}" if region
        end
      end
    end
    CASES.each do |name, sort|
      microflow "Case#{name}" do
        retrieve_objects 'Views.Shop', as: :items, sort: sort
        create_variable :names, type: :String, value: "''"
        loop_over :items, as: :item do
          change_variable :names, to: "$names + $item/Name + ','"
        end
        log_message "ORACLE #{name}={1}", node: "'ORACLE'", parameters: ['$names']
      end
    end
    microflow :RunAll do
      return_type :Boolean
      call_microflow 'Views.Seed'
      CASES.each_key { call_microflow "Views.Case#{_1}" }
      return_value 'true'
    end
    page :Home do
      title 'Association sort oracle'
      button('Run', caption: 'Run') { on_click microflow: 'Views.RunAll' }
    end
  end
  navigation { profile :Responsive, home_page: 'Views.Home' }
end
# rubocop:enable Metrics/BlockLength
