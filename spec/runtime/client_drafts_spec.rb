# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Runtime::ClientDrafts do
  around do |example|
    Dir.mktmpdir do |directory|
      source = File.join(directory, 'Drafts.mpr')
      Mxrb.define(source) do
        self.module(:Drafts) { entity(:Item) { string :Name } }
      end
      @project = Mxrb.open(source)
      @path = File.join(directory, 'data.sqlite3')
      @store = Mxrb::Runtime::SQLiteStore.new(@project, path: @path)
      example.run
    ensure
      @store&.close
      @other&.close
      @project&.close
    end
  end

  def detached(members = {})
    @store.transaction do
      @store.create('Drafts.Item').tap { _1.members.merge!(members) }
    end
  end

  def resume(store, object, token, owner: 'alice')
    store.client_drafts.resume(token, entity: object.entity, id: object.id, owner:)
  end

  it 'resumes private cyclic graphs in another process with dates and durable associations intact' do
    durable = @store.create('Drafts.Item')
    @store.commit(durable)
    first = detached('Name' => 'Hidden server default', 'Date' => Date.new(2026, 10, 5),
                     'DateTime' => DateTime.new(2026, 10, 5, 12, 30, 15, '-04:00'),
                     'Time' => Time.utc(2026, 10, 5, 12, 30, 1, 123_456))
    second = detached('Parent' => first)
    first.members['Links'] = [second, durable, nil, true, 4]
    token = @store.client_drafts.capture(first, owner: 'alice')
    expect(@store.client_drafts.capture(first, owner: 'alice')).to eq(token)
    @store.release_cache!
    @other = Mxrb::Runtime::SQLiteStore.new(@project, path: @path)
    restored = resume(@other, first, token)
    expect(restored.members.except('Links')).to eq(first.members.except('Links'))
    links = restored.members.fetch('Links')
    expect(links.first.members.fetch('Parent')).to equal(restored)
    expect(links.drop(1)).to eq([@other.find(durable.entity, durable.id), nil, true, 4])
    expect(resume(@other, first, token)).to equal(restored)
    @other.commit(links.first)
    @other.release_cache!
    expect(@other.retrieve('Drafts.Item').map(&:id)).to eq([durable.id, second.id])
    expect(resume(@other, first, token).members.fetch('Links').first.id).to eq(second.id)
  end

  it 'rejects wrong users, altered identities, expired capabilities and replay after commit or deletion' do
    value = detached('Name' => 'Private')
    token = @store.client_drafts.capture(value, owner: 'alice')
    expect { resume(@store, value, token, owner: 'bob') }.to raise_error(Mxrb::NativeRuntimeError, /another user/)
    expect { resume(@store, value, 'forged') }.to raise_error(Mxrb::NativeRuntimeError)
    expect do
      @store.client_drafts.resume(token, entity: 'Drafts.Other', id: value.id, owner: 'alice')
    end.to raise_error(Mxrb::NativeRuntimeError)
    @store.release_cache!
    resumed = resume(@store, value, token)
    @store.commit(resumed, events: false)
    @store.delete(resumed, events: false)
    expect { resume(@store, value, token) }.to raise_error(Mxrb::NativeRuntimeError)
    deleted = detached
    deleted_token = @store.client_drafts.capture(deleted, owner: 'alice')
    @store.delete(deleted, events: false)
    expect { resume(@store, deleted, deleted_token) }.to raise_error(Mxrb::NativeRuntimeError)
    rolled_back = detached
    rollback_token = @store.client_drafts.capture(rolled_back, owner: 'alice')
    @store.rollback(rolled_back)
    expect { resume(@store, rolled_back, rollback_token) }.to raise_error(Mxrb::NativeRuntimeError)
    expiring = detached
    expired_token = @store.client_drafts.capture(expiring, owner: 'alice')
    @store.database.execute('UPDATE mxrb_client_drafts SET expires_at = 0')
    expect { resume(@store, expiring, expired_token) }.to raise_error(Mxrb::NativeRuntimeError, /expired/)
    @store.client_drafts.capture(detached, owner: 'alice')
    expect(@store.database.get_first_value('SELECT COUNT(*) FROM mxrb_client_drafts WHERE token = ?', expired_token))
      .to eq(0)
  end

  it 'restores a capability when a commit is rolled back and never snapshots a failed edit' do
    original = detached('Name' => 'Original')
    token = @store.client_drafts.capture(original, owner: 'alice')
    @store.release_cache!
    expect do
      @store.transaction do
        value = resume(@store, original, token)
        value.members['Name'] = 'Failed'
        @store.commit(value)
        raise 'Rollback this Save'
      end
    end.to raise_error('Rollback this Save')
    @store.release_cache!
    restored = resume(@store, original, token)
    expect(restored.members.fetch('Name')).to eq('Original')
    @store.transaction { restored.members['Name'] = 'Unsaved change' }
    expect(resume(@store, original, token).members.fetch('Name')).to eq('Unsaved change')
    expect(@store.detached_draft('Drafts.Other', original.id)).to be_nil
    @store.release_cache!
    expect(@store.retrieve('Drafts.Item')).to eq([])
  end
end
# rubocop:enable Metrics/BlockLength
