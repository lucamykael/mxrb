# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Exported frontend nanoflow lists' do
  it 'compiles list creation and mutation into executable TypeScript' do
    Dir.mktmpdir do |root|
      source = File.join(root, 'Application.mpr')
      Mxrb.define(source) do
        self.module :Lists do
          entity(:Item) { string :Name }
          nanoflow :Run do
            create_list 'Lists.Item', as: :items
            create_object 'Lists.Item', as: :item
            change_list :items, action: :add, value: '$item'
          end
        end
      end
      target = File.join(root, 'ruby')
      Mxrb::Exporter.new(source, target, mode: :ruby).export!
      code = Dir[File.join(target, 'frontend/src/generated/nanoflows/**/*.ts')].map { File.read(_1) }.join
      expect(code).to include('runtime.set("items", []);', 'runtime.changeList("items", "Add", "$item");')
      expect(code).not_to include('runtime.unsupported')
    end
  end
end
