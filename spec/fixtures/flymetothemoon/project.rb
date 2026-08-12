# frozen_string_literal: true

require 'mxrb'

output = ENV.fetch('MXRB_OUTPUT_PATH')

# rubocop:disable Metrics/BlockLength
Mxrb.define(output) do
  mendix_version '11.12.1'

  self.module :Certification do
    enumeration :OrderStatus do
      value :Submitted, caption: 'Submitted'
      value :Processing, caption: 'Processing'
      value :Done, caption: 'Done'
    end

    entity :Customer do
      string :Name, required: true
      string :Email
      boolean :Active, default: true
      index :Email
    end

    entity :Product do
      string :Sku, required: true, unique: true
      string :Name, required: true
      decimal :Price, default: '0'
      integer :Stock, default: 0
    end

    entity :Order do
      string :Number, required: true
      enum :Status, enumeration: 'Certification.OrderStatus', default: 'Submitted'
      decimal :Total, default: '0'
      datetime :PlacedAt
      association 'Certification.Customer', name: 'Order_Customer', cardinality: :many_to_one
      index :Number
    end

    entity :OrderLine do
      integer :Quantity, default: 1
      decimal :UnitPrice, default: '0'
      association 'Certification.Order', name: 'OrderLine_Order', cardinality: :many_to_one
      association 'Certification.Product', name: 'OrderLine_Product', cardinality: :many_to_one
    end

    microflow :SeedOrder do
      return_type 'Certification.Order'
      create_object(
        'Certification.Order', as: :order, commit: true,
                               set: { Number: "'CERT-001'", Total: '42.5' }
      )
      return_value '$order'
    end

    microflow :CountOrders do
      return_type :Integer
      retrieve_objects 'Certification.Order', as: :orders
      aggregate :orders, function: :count, as: :count
      return_value '$count'
    end

    microflow :ChoosePriority do
      parameter :Urgent, type: :Boolean
      return_type :String
      decision '$Urgent' do
        on(true) { return_value "'high'" }
        on(false) { return_value "'normal'" }
      end
    end

    microflow :DeleteOrders do
      retrieve_objects 'Certification.Order', as: :orders
      delete :orders
    end

    nanoflow :ClientRefresh do
      call_microflow 'Certification.CountOrders', as: :count
      return_value '$count'
    end
    scheduled_event :DailyOrderAudit, microflow: 'Certification.CountOrders', interval: 1, unit: :days

    page :Dashboard do
      text :Heading, caption: 'Order certification'
      data_grid :Orders, entity: 'Certification.Order' do
        column :Number, attribute: 'Certification.Order/Number', caption: 'Number'
        column :Status, attribute: 'Certification.Order/Status', caption: 'Status'
        column :Total, attribute: 'Certification.Order/Total', caption: 'Total'
      end
      button :Seed, caption: 'Seed order' do
        on_click microflow: 'Certification.SeedOrder'
      end
      button :Refresh, caption: 'Refresh count' do
        on_click nanoflow: 'Certification.ClientRefresh'
      end
    end
  end

  navigation do
    profile :Responsive, home_page: 'Certification.Dashboard'
  end
end
# rubocop:enable Metrics/BlockLength
