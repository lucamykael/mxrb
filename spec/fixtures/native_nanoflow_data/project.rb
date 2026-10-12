# frozen_string_literal: true

require 'mxrb'

# Client oracle: Probe.Load seeds rows on the server; each button runs one nanoflow that logs
# "ORACLE <case>=<value>" in the browser console. Run with script/client_native_oracle.
rows = [['North', 3, '2.5', true], ['south', 1, '7', false], ['Middle', 2, nil, true], ['alpha', 2, '-1.25', false]]
# rubocop:disable Metrics/BlockLength
Mxrb.define(ENV.fetch('MXRB_OUTPUT_PATH')) do
  mendix_version '11.12.1'
  self.module :Probe do
    entity(:Item) { string :Name }
    entity :Row do
      string :Name
      integer :Rank
      decimal :Amount
      boolean :Active
      association 'Probe.Item', name: :Row_Item, cardinality: :many_to_one
    end
    microflow :Load do
      create_object 'Probe.Item', as: :item, set: { Name: "'probe'" }, commit: true
      rows.each_with_index do |(name, rank, amount, active), index|
        create_object 'Probe.Row', as: "r#{index}", commit: true do
          set :Name, to: "'#{name}'"
          set :Rank, to: rank.to_s
          set :Amount, to: amount || 'empty'
          set :Active, to: active.to_s
          set_association 'Probe.Row_Item', to: '$item'
        end
      end
      return_type 'Probe.Item'
      return_value '$item'
    end
    cases = {
      'RetrieveSorted' => proc {
        retrieve_objects 'Probe.Row', as: :rows, sort: [['Probe.Row.Name', 'Ascending']]
        create_variable :names, type: :String, value: "''"
        loop_over(:rows, as: :it) { change_variable :names, to: "$names + $it/Name + ','" }
        log_message 'ORACLE RetrieveSorted={1}', parameters: ['$names']
      },
      'RetrieveXPath' => proc {
        retrieve_objects 'Probe.Row', as: :rows, xpath: "[Name = 'NORTH' or Rank > 2]",
                                      sort: [['Probe.Row.Rank', 'Descending']]
        create_variable :names, type: :String, value: "''"
        loop_over(:rows, as: :it) { change_variable :names, to: "$names + $it/Name + ','" }
        log_message 'ORACLE RetrieveXPath={1}', parameters: ['$names']
      },
      'RetrieveFirst' => proc {
        retrieve_objects 'Probe.Row', as: :first, single: true, sort: [['Probe.Row.Amount', 'Descending']]
        log_message 'ORACLE RetrieveFirst={1}', parameters: ['$first/Name']
      },
      'Aggregates' => proc {
        retrieve_objects 'Probe.Row', as: :rows
        aggregate :rows, function: :count, as: :count
        aggregate :rows, function: :sum, attribute: 'Probe.Row.Amount', as: :sum
        aggregate :rows, function: :average, attribute: 'Probe.Row.Amount', as: :avg
        aggregate :rows, function: :maximum, attribute: 'Probe.Row.Rank', as: :max
        aggregate :rows, function: :minimum, attribute: 'Probe.Row.Amount', as: :min
        log_message 'ORACLE Aggregates={1}|{2}|{3}|{4}|{5}',
                    parameters: ['toString($count)', 'toString($sum)', 'toString($avg)', 'toString($max)',
                                 'toString($min)']
      },
      'ListOps' => proc {
        retrieve_objects 'Probe.Row', as: :rows, sort: [['Probe.Row.Name', 'Ascending']]
        list_operation :head, :rows, as: :head
        list_operation :tail, :rows, as: :tail
        list_operation :tail, :tail, as: :active
        list_operation :sort, :rows, sort: [['Probe.Row.Name', :descending]], as: :sorted
        list_operation :subtract, :rows, with: :active, as: :rest
        list_operation :union, :active, with: :rest, as: :all
        list_operation :intersect, :rows, with: :active, as: :both
        list_operation :contains, :rows, with: :head, as: :has
        aggregate :tail, function: :count, as: :tails
        aggregate :all, function: :count, as: :alls
        aggregate :both, function: :count, as: :boths
        create_variable :names, type: :String, value: "''"
        loop_over(:sorted, as: :it) { change_variable :names, to: "$names + $it/Name + ','" }
        log_message 'ORACLE ListOps={1}|{2}|{3}|{4}|{5}|{6}',
                    parameters: ['$head/Name', 'toString($tails)', '$names', 'toString($alls)', 'toString($boths)',
                                 'toString($has)']
      },
      'Loops' => proc {
        retrieve_objects 'Probe.Row', as: :rows, sort: [['Probe.Row.Name', 'Ascending']]
        create_variable :names, type: :String, value: "''"
        loop_over(:rows, as: :it) do
          decision('$it/Rank = 1') do
            on(true) { continue_loop }
            on(false) {}
          end
          change_variable :names, to: "$names + $it/Name + ','"
          decision('$it/Name = \'North\'') do
            on(true) { break_loop }
            on(false) {}
          end
        end
        create_variable :counter, type: :Integer, value: '0'
        while_loop('$counter < 3') { change_variable :counter, to: '$counter + 1' }
        log_message 'ORACLE Loops={1}|{2}', parameters: ['$names', 'toString($counter)']
      },
      'Association' => proc {
        retrieve_objects 'Probe.Row', as: :first, single: true, sort: [['Probe.Row.Name', 'Ascending']]
        retrieve_association :first, association: 'Probe.Row_Item', as: :item
        log_message 'ORACLE Association={1}', parameters: ['$item/Name']
      },
      'CommitDelete' => proc {
        create_object 'Probe.Row', as: :new, set: { Name: "'zeta'", Rank: '9', Active: 'true' }
        commit :new
        retrieve_objects 'Probe.Row', as: :after
        aggregate :after, function: :count, as: :n1
        delete :new
        retrieve_objects 'Probe.Row', as: :gone
        aggregate :gone, function: :count, as: :n2
        log_message 'ORACLE CommitDelete={1}|{2}', parameters: ['toString($n1)', 'toString($n2)']
      },
      'Rollback' => proc {
        retrieve_objects 'Probe.Row', as: :first, single: true, sort: [['Probe.Row.Name', 'Ascending']]
        change_object :first, set: { Name: "'changed'" }
        rollback :first
        log_message 'ORACLE Rollback={1}', parameters: ['$first/Name']
      },
      'SortNull' => proc {
        retrieve_objects 'Probe.Row', as: :rows, sort: [['Probe.Row.Name', 'Ascending']]
        list_operation :sort, :rows, sort: [['Probe.Row.Amount', :ascending]], as: :asc
        list_operation :sort, :rows, sort: [['Probe.Row.Amount', :descending]], as: :desc
        create_variable :a, type: :String, value: "''"
        loop_over(:asc, as: :it) { change_variable :a, to: "$a + $it/Name + ','" }
        create_variable :d, type: :String, value: "''"
        loop_over(:desc, as: :it2) { change_variable :d, to: "$d + $it2/Name + ','" }
        log_message 'ORACLE SortNull={1}|{2}', parameters: ['$a', '$d']
      },
      'AggEmpty' => proc {
        retrieve_objects 'Probe.Row', as: :none, xpath: '[Rank > 100]'
        aggregate :none, function: :count, as: :count
        aggregate :none, function: :sum, attribute: 'Probe.Row.Amount', as: :sum
        aggregate :none, function: :average, attribute: 'Probe.Row.Amount', as: :avg
        aggregate :none, function: :maximum, attribute: 'Probe.Row.Amount', as: :max
        log_message 'ORACLE AggEmpty={1}|{2}|{3}|{4}',
                    parameters: ['toString($count)', 'toString($sum)', 'toString($avg)',
                                 'if $max = empty then \'<empty>\' else toString($max)']
      },
      'FindExpr' => proc {
        retrieve_objects 'Probe.Row', as: :rows, sort: [['Probe.Row.Name', 'Ascending']]
        list_operation :find_by_expression, :rows, expression: '$currentObject/Rank = 2', as: :found
        list_operation :filter_by_expression, :rows, expression: '$currentObject/Active', as: :active
        aggregate :active, function: :count, as: :n
        log_message 'ORACLE FindExpr={1}|{2}', parameters: ['$found/Name', 'toString($n)']
      },
      'VarXPath' => proc {
        create_variable :minimum, type: :Integer, value: '2'
        retrieve_objects 'Probe.Row', as: :rows, xpath: '[Rank >= $minimum]', sort: [['Probe.Row.Name', 'Ascending']]
        create_variable :names, type: :String, value: "''"
        loop_over(:rows, as: :it) { change_variable :names, to: "$names + $it/Name + ','" }
        log_message 'ORACLE VarXPath={1}', parameters: ['$names']
      },
      'ObjectXPath' => proc {
        retrieve_objects 'Probe.Item', as: :item, single: true
        retrieve_objects 'Probe.Row', as: :rows, xpath: '[Probe.Row_Item = $item]'
        aggregate :rows, function: :count, as: :n
        log_message 'ORACLE ObjectXPath={1}', parameters: ['toString($n)']
      },
      'Limit' => proc {
        retrieve_objects 'Probe.Row', as: :rows, limit: '2', sort: [['Probe.Row.Name', 'Descending']]
        create_variable :names, type: :String, value: "''"
        loop_over(:rows, as: :it) { change_variable :names, to: "$names + $it/Name + ','" }
        log_message 'ORACLE Limit={1}', parameters: ['$names']
      }
    }
    cases.each { |name, body| nanoflow("Case#{name}", &body) }
    page :Home do
      title 'Nanoflow oracle'
      data_source microflow: 'Probe.Load'
      text_box :Name, attribute: 'Probe.Item.Name', caption: 'Name'
      cases.each_key { |name| button(name, caption: name) { on_click nanoflow: "Probe.Case#{name}" } }
    end
  end
  navigation { profile :Responsive, home_page: 'Probe.Home' }
end
# rubocop:enable Metrics/BlockLength
