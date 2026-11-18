# frozen_string_literal: true

require 'mxrb'

Mxrb.define(ENV.fetch('MXRB_OUTPUT_PATH')) do
  mendix_version '11.12.1'
  self.module(:Sales) do
    entity(:Customer) { string :Name }
    entity(:Order) do
      decimal :Total
      association 'Sales.Customer', name: :Order_Customer
    end
    microflow(:CreateOrder) { call_microflow 'Sales.ValidateOrder' }
    microflow(:ValidateOrder)
  end
  self.module(:Billing) { microflow(:Charge) }
end
