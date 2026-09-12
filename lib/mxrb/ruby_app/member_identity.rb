# frozen_string_literal: true

require_relative '../errors'

module Mxrb
  module RubyApp
    # Reconciles a complete named collection against its private identities.
    # A missing ID remains missing only for an unambiguous insertion; this
    # boundary never generates IDs or guesses identity from collection order.
    class MemberIdentity
      Member = Data.define(:name, :id)

      def self.resolve(previous:, declarations:, removed: [])
        new(previous:, declarations:, removed:).resolve
      end

      def initialize(previous:, declarations:, removed: [])
        @previous = previous.map do |entry|
          Member.new(name: field(entry, :name).to_s, id: field(entry, :id).to_s)
        end
        @declarations = declarations.map(&:dup)
        @removed = removed.map(&:to_s).uniq
        @bound = {}
        @claims = {}
        validate_collections!
        @by_id = @previous.to_h { [_1.id, _1] }
        @by_name = @previous.to_h { [_1.name, _1] }
      end

      def resolve
        bind_explicit_ids!
        bind_renames!
        bind_names!
        reject_ambiguous_changes!
        @declarations.map.with_index do |declaration, index|
          member = @bound[index]
          member ? declaration.merge(id: member.id) : declaration.dup
        end
      end

      private

      def field(entry, name)
        entry.key?(name) ? entry.fetch(name) : entry.fetch(name.to_s)
      end

      def validate_collections!
        validate_names!(@previous.map(&:name), 'previous members')
        validate_names!(@declarations.map { _1.fetch(:name).to_s }, 'declared members')
        validate_names!(@removed, 'removed members')
        ids = @previous.map(&:id)
        raise ValidationError, 'private member identities are missing or duplicated' if ids.any?(&:empty?) ||
                                                                                        ids.uniq.size != ids.size

        declared_ids = @declarations.map { _1[:id].to_s }.reject(&:empty?)
        raise ValidationError, 'duplicate explicit member identities' unless declared_ids.uniq.size == declared_ids.size
      end

      def validate_names!(names, label)
        return unless names.any?(&:empty?) || names.uniq.size != names.size

        raise ValidationError, "empty or duplicate names in #{label}"
      end

      def bind_explicit_ids!
        @declarations.each_with_index do |declaration, index|
          id = declaration[:id].to_s
          next if id.empty?

          if (member = @by_id[id])
            bind!(index, member)
          elsif @by_name.key?(declaration.fetch(:name).to_s)
            raise ValidationError, "explicit identity conflicts with member #{declaration.fetch(:name)}"
          end
        end
      end

      def bind_renames!
        @declarations.each_with_index do |declaration, index|
          next unless declaration.key?(:renamed_from)

          old_name = declaration.fetch(:renamed_from).to_s
          raise ValidationError, 'renamed_from must name an existing member' if old_name.empty?

          # The declaration survives re-export: after its first application,
          # the old name is absent and the current name already has the ID.
          member = @by_name[old_name] || @by_name[declaration.fetch(:name).to_s]
          raise ValidationError, "unknown member rename source #{old_name}" unless member

          supplied_id = declaration[:id].to_s
          unless supplied_id.empty? || supplied_id == member.id
            raise ValidationError, "explicit identity conflicts with renamed member #{old_name}"
          end

          bind!(index, member)
        end
      end

      def bind_names!
        @declarations.each_with_index do |declaration, index|
          next if @bound.key?(index) || !declaration[:id].to_s.empty?

          member = @by_name[declaration.fetch(:name).to_s]
          bind!(index, member) if member
        end
      end

      def bind!(index, member)
        name = @declarations.fetch(index).fetch(:name).to_s
        named = @by_name[name]
        raise ValidationError, "member rename collides with existing name #{name}" if named && named.id != member.id
        if @removed.include?(member.name)
          raise ValidationError, "member #{member.name} cannot be both removed and retained or renamed"
        end
        if @claims.key?(member.id) && @claims[member.id] != index
          raise ValidationError, "multiple declarations claim member #{member.name}"
        end

        @claims[member.id] = index
        @bound[index] = member
      end

      def reject_ambiguous_changes!
        unmatched_previous = @previous.reject { @claims.key?(_1.id) || @removed.include?(_1.name) }
        unmatched_new = @declarations.each_index.select do |index|
          !@bound.key?(index) && @declarations[index][:id].to_s.empty?
        end
        return if unmatched_previous.empty? || unmatched_new.empty?

        raise ValidationError,
              'cannot distinguish member renames from removal and insertion; use renamed_from: or remove_value'
      end
    end
  end
end
