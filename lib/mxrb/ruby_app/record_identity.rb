# frozen_string_literal: true

require_relative 'member_identity'

module Mxrb
  module RubyApp
    # Reconciles domain declarations against private metadata without restoring
    # values or guessing correspondence from collection positions.
    class RecordIdentity
      COLLECTIONS = %i[associations access_rules indexes lifecycle validation_rules].freeze

      def initialize(manifest)
        records = manifest.modules.flat_map { Array(_1['models']) + Array(_1['dtos']) }
        @records = records.group_by { _1.fetch('id').to_s }
      end

      def resolve(id:, name:, removed: {}, **declarations)
        matches = @records.fetch(id.to_s, [])
        raise ValidationError, 'ambiguous private record identity' if matches.size > 1

        baseline = matches.first
        result = declarations.dup
        COLLECTIONS.each do |collection|
          if declarations[collection].nil? && !removed.fetch(collection, []).empty?
            raise ValidationError, "domain removal requires explicit complete #{collection} declarations"
          end
          next if declarations[collection].nil?

          previous = baseline_collection(baseline, collection)
          result[collection] = resolve_collection(collection, previous, declarations.fetch(collection),
                                                  removed.fetch(collection, []), name)
        end
        %i[generalization oql_view].each do |singleton|
          next unless declarations[singleton]
          if baseline && !baseline.key?(singleton.to_s)
            raise ValidationError, "existing record requires its #{singleton} identity baseline"
          end

          prior = baseline && baseline[singleton.to_s]
          fields = singleton == :oql_view ? %i[source_id document_id] : [:id]
          result[singleton] = identities(declarations.fetch(singleton), prior, fields)
        end
        result
      end

      # Shared with emission: duplicate anonymous ACL signatures cannot be
      # distinguished safely without their legacy explicit identity.
      def self.access_key(rule)
        [*access_signature(rule), field(rule, :source_identity).to_s]
      end

      def self.access_signature(rule)
        [Array(field(rule, :roles)).map(&:to_s).sort, field(rule, :xpath).to_s]
      end

      def self.field(entry, key)
        entry.key?(key) ? entry[key] : entry[key.to_s]
      end

      private

      def field(entry, key) = self.class.field(entry, key)

      def baseline_collection(baseline, collection)
        return [] unless baseline

        values = baseline[collection.to_s]
        raise ValidationError, "existing record requires its #{collection} identity baseline" unless values.is_a?(Array)

        values
      end

      def resolve_collection(kind, previous, declarations, removed, owner)
        key = ->(entry) { signature(kind, entry, owner) }
        declarations = declarations.map do |entry|
          if entry.key?(:renamed_from)
            entry.merge(renamed_from: rename_signature(kind, entry[:renamed_from],
                                                       owner))
          else
            entry
          end
        end
        resolved = reconcile(previous, declarations, removed.map { rename_signature(kind, _1, owner) }, &key)
        by_id = previous.to_h { [field(_1, :id).to_s, _1] }
        resolved.map do |entry|
          prior = by_id[entry[:id].to_s]
          case kind
          when :access_rules
            entry.merge(members: reconcile(baseline_collection(prior, :members), entry.fetch(:members), []) do |member|
              signature(:access_member, member, owner)
            end)
          when :indexes
            identities(entry, prior, [:guid]).merge(
              members: reconcile(baseline_collection(prior, :members), entry.fetch(:members), []) do |member|
                signature(:index_member, member, owner)
              end
            )
          when :validation_rules
            identities(entry, prior, %i[message_id rule_info_id]).merge(
              translations: reconcile(baseline_collection(prior, :translations), entry.fetch(:translations),
                                      []) do |translation|
                field(translation, :language_code).to_s
              end
            )
          else entry
          end
        end
      end

      def reconcile(previous, declarations, removed, &signature)
        duplicate_keys = previous.group_by(&signature).select { |_, entries| entries.size > 1 }.keys
        by_id = previous.to_h { [field(_1, :id).to_s, _1] }
        previous_names = previous.map do |entry|
          key = signature.call(entry)
          name = duplicate_keys.include?(key) ? legacy_name(field(entry, :id)) : JSON.generate(key)
          { name:, id: field(entry, :id) }
        end
        decorated = declarations.map do |entry|
          prior = by_id[entry[:id].to_s]
          key = signature.call(entry)
          if duplicate_keys.include?(key) && !prior
            raise ValidationError, 'ambiguous domain member signature requires an explicit legacy id'
          end

          name = if prior && duplicate_keys.include?(signature.call(prior))
                   legacy_name(entry[:id])
                 else
                   JSON.generate(key)
                 end
          entry.merge(name:).tap do |decorated_entry|
            decorated_entry[:renamed_from] = JSON.generate(entry[:renamed_from]) if entry.key?(:renamed_from)
          end
        end
        resolved = MemberIdentity.resolve(previous: previous_names, declarations: decorated,
                                          removed: removed.map { JSON.generate(_1) })
        resolved.zip(declarations).map do |entry, original|
          original.merge(id: entry[:id])
        end
      rescue ValidationError => e
        raise ValidationError, e.message.sub('remove_value', 'an explicit domain removal or legacy id')
      end

      def legacy_name(id) = "legacy:#{id}"

      def rename_signature(kind, value, owner)
        case kind
        when :associations then value.to_s.split('.').last
        when :lifecycle then value.to_s
        when :indexes
          Array(value).map do |member|
            member.is_a?(Array) ? [member.fetch(0).to_s, index_member_type(member.fetch(1))] : [member.to_s, 'Normal']
          end
        when :access_rules
          unless value.is_a?(Array) && value.size == 2
            raise ArgumentError,
                  'access-rule renamed_from requires [roles, xpath]'
          end

          [Array(value.first).map(&:to_s).sort, value.last.to_s, '']
        when :validation_rules
          unless value.is_a?(Array) && value.size == 2
            raise ArgumentError,
                  'validation renamed_from requires [attribute, kind]'
          end

          signature(kind, { attribute: value.first, kind: value.last }, owner)
        end
      end

      def identities(declaration, previous, fields)
        fields.each_with_object(declaration.dup) do |key, result|
          supplied = declaration[key].to_s
          prior = previous && field(previous, key).to_s
          if !supplied.empty? && prior && !prior.empty? && supplied != prior
            raise ValidationError, "native identity mismatch for domain #{key}"
          end

          result[key] = prior if supplied.empty? && prior && !prior.empty?
        end
      end

      def signature(kind, entry, owner)
        case kind
        when :associations then field(entry, :name).to_s.split('.').last
        when :access_rules then self.class.access_key(entry)
        when :indexes then Array(field(entry, :members)).map { signature(:index_member, _1, owner) }
        when :index_member then [field(entry, :name).to_s, index_member_type(field(entry, :type) || 'Normal')]
        when :lifecycle then field(entry, :event).to_s
        when :validation_rules
          kind = field(entry, :kind).to_s
          kind = 'DomainModels$RegExRuleInfo' if kind == 'regular_expression'
          kind = "DomainModels$#{kind.capitalize}RuleInfo" if %w[required unique].include?(kind.downcase)
          [field(entry, :attribute).to_s, kind]
        when :access_member
          kind = (field(entry, :kind) || 'attribute').to_s
          reference = field(entry, :reference).to_s
          prefix = kind == 'association' ? owner.split('.').first : owner
          reference = "#{prefix}.#{field(entry, :name)}" if reference.empty?
          [kind, reference]
        end
      end

      def index_member_type(value)
        { 'normal' => 'Normal', 'created_date' => 'CreatedDate', 'changed_date' => 'ChangedDate',
          'owner' => 'Owner', 'changed_by' => 'ChangedBy' }.fetch(value.to_s, value.to_s)
      end
    end
  end
end
