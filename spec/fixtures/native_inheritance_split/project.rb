# frozen_string_literal: true

# Which branch an object type decision takes on Mendix 11.12.1 when the object
# is of the type of a branch, of a specialization of one or of none, and what
# the cast after a branch gives. Views.RunAll runs after startup and logs one
# "ORACLE <case>=<value>" line each.

require 'mxrb'

output_path = ENV.fetch('MXRB_OUTPUT_PATH')
oracle = "'ORACLE'"

# rubocop:disable Metrics/BlockLength
Mxrb.define(output_path) do
  mendix_version '11.12.1'
  self.module :Views do
    entity(:Base) { string :Name }
    entity(:Middle) { generalizes 'Views.Base' }
    entity(:Leaf) { generalizes 'Views.Middle' }
    entity(:Other) { generalizes 'Views.Base' }
    page :Home do
      title 'Inheritance split oracle'
    end
    microflow :Classify do
      parameter :Item, type: 'Views.Base'
      return_type :String
      type_decision :Item do
        on_type 'Views.Middle' do
          cast :AsMiddle
          return_value "'middle:' + $AsMiddle/Name"
        end
        on_type 'Views.Base' do
          cast :AsBase
          return_value "'base:' + $AsBase/Name"
        end
        otherwise do
          return_value "'none'"
        end
      end
    end
    microflow :RunAll do
      return_type :Boolean
      { base: 'Views.Base', middle: 'Views.Middle', leaf: 'Views.Leaf', other: 'Views.Other' }.each do |name, entity|
        create_object entity, as: name, set: { Name: "'#{name}'" }
        call_microflow 'Views.Classify', as: :"#{name}Branch" do
          argument 'Views.Classify.Item', "$#{name}"
        end
        log_message "ORACLE #{name}=[{1}]", node: oracle, parameters: ["$#{name}Branch"]
      end
      return_value 'true'
    end
  end
  navigation { profile :Responsive, home_page: 'Views.Home' }
end
# rubocop:enable Metrics/BlockLength
