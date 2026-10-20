# frozen_string_literal: true

require 'spec_helper'

# The captions Studio Pro generates for automatic activity captions, as MxBuild
# 11.12.1 and 11.12.3 wrote them for the Sudoku and Native Mobile Resources
# projects.
# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Compiler::ActivityCaption do
  let(:source) do
    unit = Struct.new(:module_name, :document)
    model = Struct.new(:code_actions, :settings) do
      def units_of(type) = code_actions.fetch(type, [])
      def documents(type) = type == 'Settings$ProjectSettings' ? settings : []
    end
    model.new(
      {
        'JavaActions$JavaAction' => [unit.new('Images', { 'Name' => 'Generate',
                                                          'MicroflowActionInfo' => { 'Caption' => 'Set image' } })],
        'JavaScriptActions$JavaScriptAction' => [unit.new('Commons', { 'Name' => 'Plain' })]
      },
      [{ 'Settings' => [2, { '$Type' => 'Settings$LanguageSettings', 'DefaultLanguageCode' => 'nl_NL' }] }]
    )
  end
  let(:captions) { described_class.new(source) }

  def item(attribute: '', association: '') = { '$Type' => 'Microflows$ChangeActionItem', 'Attribute' => attribute,
                                               'Association' => association }

  def caption(type, variables: {}, retrieve_type: nil, **action)
    captions.caption(action.transform_keys(&:to_s).merge('$Type' => "Microflows$#{type}"),
                     variables:, retrieve_type:)
  end

  it 'names object changes by their entity or variable and the members they set' do
    items = [2, item(attribute: 'App.Order.Total'), item(association: 'App.Order_Customer')]
    expect(caption('CreateChangeAction', Entity: 'App.Order', Items: items))
      .to eq('Create Order (Total, Order_Customer)')
    expect(caption('CreateChangeAction', Entity: 'App.Order', Items: [2])).to eq('Create Order')
    expect(caption('ChangeAction', ChangeVariableName: 'Order', Items: items))
      .to eq("Change 'Order' (Total, Order_Customer)")
    expect(caption('ChangeVariableAction', ChangeVariableName: 'Count')).to eq('Change variable Count')
    expect(caption('CommitAction', CommitVariableName: 'Order')).to eq("Commit 'Order'")
  end

  it 'names variables, deletes and retrieves by their types' do
    {
      'DataTypes$BooleanType' => 'Create Boolean variable', 'DataTypes$IntegerType' => 'Create Integer/Long variable',
      'DataTypes$StringType' => 'Create String variable', 'DataTypes$ObjectType' => nil
    }.each do |type, expected|
      expect(caption('CreateVariableAction',
                     VariableType: { '$Type' => type })).to eq(expected)
    end
    variables = { 'Order' => 'App.Order', 'Lines' => '[App.Line]' }
    expect(caption('DeleteAction', DeleteVariableName: 'Order', variables:)).to eq("Delete 'Order'")
    expect(caption('DeleteAction', DeleteVariableName: 'Lines', variables:)).to eq("Delete objects in 'Lines'")
    expect(caption('DeleteAction', DeleteVariableName: 'Unknown', variables:)).to be_nil
    database = lambda do |range|
      caption('RetrieveAction', RetrieveSource: { '$Type' => 'Microflows$DatabaseRetrieveSource',
                                                  'Entity' => 'App.Line', 'Range' => range })
    end
    expect(database.call({ '$Type' => 'Microflows$ConstantRange', 'SingleObject' => true }))
      .to eq('Retrieve Line from database')
    expect(database.call({ '$Type' => 'Microflows$ConstantRange', 'SingleObject' => false }))
      .to eq('Retrieve list of Line from database')
    association = { '$Type' => 'Microflows$AssociationRetrieveSource', 'StartVariableName' => 'Order',
                    'AssociationId' => 'App.Line_Order' }
    expect(caption('RetrieveAction', RetrieveSource: association, retrieve_type: '[App.Line]'))
      .to eq('Retrieve list of Line by $Order/Line_Order')
    expect(caption('RetrieveAction', RetrieveSource: association, retrieve_type: 'App.Line'))
      .to eq('Retrieve Line by $Order/Line_Order')
    expect(caption('RetrieveAction', RetrieveSource: association)).to be_nil
    expect(caption('RetrieveAction', RetrieveSource: { '$Type' => 'Microflows$Other' })).to be_nil
  end

  it 'names lists, pages, messages, calls and client actions' do
    expect(caption('CreateListAction', Entity: 'App.Line')).to eq('Create list of Line')
    expect(caption('ChangeListAction', ChangeVariableName: 'Lines', Type: 'Add')).to eq('Add to list Lines')
    expect(caption('ChangeListAction', ChangeVariableName: 'Lines', Type: 'Clear')).to eq('Clear list Lines')
    expect(caption('ChangeListAction', ChangeVariableName: 'Lines', Type: 'Remove')).to be_nil
    expect(caption('ShowFormAction', FormSettings: { 'Form' => 'App.Order_Edit' })).to eq("Show page 'Order_Edit'")
    expect(caption('CloseFormAction')).to eq('Close page')
    text = { 'Items' => [3, { 'LanguageCode' => 'en_US', 'Text' => 'Saved {1}' },
                         { 'LanguageCode' => 'nl_NL', 'Text' => 'Opgeslagen {1}' }] }
    expect(caption('ShowMessageAction', Template: { 'Text' => text })).to eq('Opgeslagen {1}')
    english = { 'Items' => [3, { 'LanguageCode' => 'en_US', 'Text' => 'Saved' }] }
    expect(caption('ShowMessageAction', Template: { 'Text' => english })).to eq('Saved')
    expect(caption('ShowMessageAction', Template: {})).to be_nil
    expect(caption('ValidationFeedbackAction', Attribute: 'App.Order.Total', ValidationVariableName: 'Order'))
      .to eq('Show validation message on member Total of Order')
    expect(caption('ValidationFeedbackAction', Attribute: '', Association: 'App.Line_Order',
                                               ValidationVariableName: 'Line'))
      .to eq('Show validation message on member Line_Order of Line')
    expect(caption('LogMessageAction', Level: 'Error')).to eq('Log message (error)')
    expect(caption('MicroflowCallAction', MicroflowCall: { 'Microflow' => 'App.ACT_Save' })).to eq('ACT_Save')
    expect(caption('NanoflowCallAction', NanoflowCall: { 'Nanoflow' => 'App.NF_Open' })).to eq('NF_Open')
    expect(caption('JavaActionCallAction', JavaAction: 'Images.Generate')).to eq('Set image')
    expect(caption('JavaScriptActionCallAction', JavaScriptAction: 'Commons.Plain')).to eq('Plain')
    expect(caption('JavaActionCallAction', JavaAction: 'Other.Missing')).to eq('Missing')
    expect(caption('CastAction')).to eq('Cast object')
    expect(caption('RestCallAction', HttpConfiguration: { 'HttpMethod' => 'Post' })).to eq('Call REST (POST)')
    expect(caption('SynchronizeAction', Type: 'All')).to eq('Synchronize everything')
    expect(caption('SynchronizeAction', Type: 'SpecificObjects')).to be_nil
    expect(caption('PushToClientAction', DataVariableName: 'Image')).to eq("Synchronize 'Image' to device")
    expect(caption('ListOperationsAction', NewOperation: { '$Type' => 'Microflows$Head' })).to eq('Head')
    expect(caption('ListOperationsAction', NewOperation: { '$Type' => 'Microflows$Tail' })).to be_nil
    expect(caption('AggregateAction', AggregateFunction: 'Count', AggregateVariableName: 'Lines'))
      .to eq('Count Lines')
    expect(caption('AggregateAction', AggregateFunction: 'Sum', AggregateVariableName: 'Lines')).to be_nil
    expect(caption('Unknown')).to be_nil
  end

  it 'reads no code actions or language from a source that offers none' do
    plain = described_class.new(Object.new)
    expect(plain.caption({ '$Type' => 'Microflows$JavaActionCallAction', 'JavaAction' => 'App.Run' })).to eq('Run')
    message = { '$Type' => 'Microflows$ShowMessageAction',
                'Template' => { 'Text' => { 'Items' => [3, { 'LanguageCode' => 'de_DE', 'Text' => 'Hallo' },
                                                        { 'LanguageCode' => 'en_US', 'Text' => 'Hello' }] } } }
    expect(plain.caption(message)).to eq('Hello')
  end
end
# rubocop:enable Metrics/BlockLength
