# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'references held as identifiers' do
  around do |example|
    Dir.mktmpdir do |directory|
      Mxrb.define(File.join(directory, 'References.mpr')) do
        mendix_version '11.12.1'
        self.module :Views do
          entity(:Target) { string :Name }
          entity(:Holder) { association 'Views.Target', name: :Holder_Target, cardinality: :many_to_one }
        end
      end
      Mxrb.open(Mxrb.last_defined_path) do |project|
        @store = Mxrb::Runtime::SQLiteStore.new(project, path: File.join(directory, 'references.sqlite3'))
        @interpreter = Mxrb::Runtime::Native::Interpreter.new(project, store: @store)
        example.run
      ensure
        @store&.close
      end
    end
  end

  it 'retrieves the object an uncommitted reference names by its identifier' do
    target = @store.create('Views.Target').tap { _1.members['Name'] = 'kept' }
    @store.commit(target)
    holder = @store.create('Views.Holder').tap { _1.members['Holder_Target'] = target.id.to_s }
    expect(@store.retrieve_association('Views.Holder_Target', holder).map(&:id)).to eq([target.id])

    operation = { '$Type' => 'Microflows$Find', 'Association' => 'Views.Holder_Target', 'Expression' => '$target' }
    found = @interpreter.send(:member_list_operation, operation, [holder], { 'target' => target })
    expect(found).to equal(holder)
  end
end
# rubocop:enable Metrics/BlockLength
