# frozen_string_literal: true

require 'bcrypt'

module Mxrb
  module Runtime
    # The persisted part of the Runtime-owned System module that applications
    # build on: users, user roles, languages and time zones, as declared by the
    # Mendix 11.12.1 System model (compiler/schemas/system-model-11.12.1.b64).
    module SystemDomain
      USER = 'System.User'
      USER_ROLE = 'System.UserRole'
      ATTRIBUTES = {
        USER => [
          ['Name', :string, '', true], ['Password', :hashstring, '', false], ['LastLogin', :datetime, nil, false],
          ['Blocked', :boolean, 'false', false], ['BlockedSince', :datetime, nil, false],
          ['Active', :boolean, 'true', false], ['FailedLogins', :integer, '0', false],
          ['WebServiceUser', :boolean, 'false', false], ['IsAnonymous', :boolean, 'false', false]
        ],
        USER_ROLE => [['ModelGUID', :string, '', false], ['Name', :string, '', false],
                      ['Description', :string, '', false]],
        'System.Language' => [['Code', :string, '', false], ['Description', :string, '', false]],
        'System.TimeZone' => [['Code', :string, '', false], ['Description', :string, '', false],
                              ['RawOffset', :integer, nil, false]]
      }.freeze
      ASSOCIATIONS = [
        ['System.UserRoles', USER, USER_ROLE, :ReferenceSet],
        ['System.User_Language', USER, 'System.Language', :Reference],
        ['System.User_TimeZone', USER, 'System.TimeZone', :Reference],
        ['System.grantableRoles', USER_ROLE, USER_ROLE, :ReferenceSet]
      ].freeze
      BCRYPT = %r{\A\$2[abxy]\$\d{2}\$[./A-Za-z0-9]{53}\z}

      module_function

      # Attribute declarations in the shape of Ruby application records.
      def record_attributes(entity)
        ATTRIBUTES.fetch(entity, []).map do |name, type, default, unique|
          { name: name.gsub(/(?<!^)([A-Z])/, '_\\1').downcase.to_sym, mendix_name: name, type:, default:,
            unique: }
        end
      end

      def entity_schemas(present)
        ATTRIBUTES.keys.reject { present.include?(_1) }.map do |entity|
          columns = ATTRIBUTES.fetch(entity).map do |name, type, default, unique|
            key = "#{entity}:#{name}"
            SchemaColumn.new(name, key, SchemaMigrator.physical_name('attribute', key),
                             SchemaMigrator::TYPE_MAP.fetch(type, 'TEXT'), type, default,
                             false, unique)
          end
          EntitySchema.new(entity, entity, SchemaMigrator.physical_name('entity', entity),
                           columns.freeze, {}.freeze)
        end
      end

      def association_schemas(present)
        ASSOCIATIONS.reject { present.include?(_1.first) }.map do |qualified, from, to, type|
          AssociationSchema.new(qualified.split('.').last, qualified, qualified,
                                SchemaMigrator.physical_name('association', qualified),
                                from, to, type)
        end
      end

      # Hashed strings are stored as BCrypt hashes, the Mendix default algorithm.
      def hash_password(value)
        text = value.to_s
        text.match?(BCRYPT) ? text : BCrypt::Password.create(text).to_s
      end

      def password_matches?(stored, supplied)
        return false if supplied.to_s.empty? || stored.to_s.empty?
        return BCrypt::Password.new(stored) == supplied.to_s if stored.to_s.match?(BCRYPT)

        stored.to_s == supplied.to_s
      end

      # System.VerifyPassword: the user name ignores case; Active, Blocked and
      # WebServiceUser do not matter.
      def verify_password(store, user_name, password)
        user = find_user(store, user_name)
        !user.nil? && password_matches?(user.members['Password'], password)
      end

      def find_user(store, user_name)
        name = user_name.to_s.downcase
        store.retrieve(USER).find { _1.members['Name'].to_s.downcase == name }
      end

      # Creates the UserRole object of every project user role at startup and keeps
      # its name and description current; ModelGUID identifies the role.
      def synchronize_roles(store, roles)
        return if roles.empty?

        existing = store.retrieve(USER_ROLE)
        roles.each do |role|
          object = existing.find { _1.members['ModelGUID'] == role.fetch(:guid) } ||
                   existing.find { _1.members['Name'] == role.fetch(:name) } || store.create(USER_ROLE)
          update_role(store, object, role)
        end
      end

      def update_role(store, object, role)
        updates = { 'ModelGUID' => role.fetch(:guid), 'Name' => role.fetch(:name),
                    'Description' => role.fetch(:description, '') }
        return if updates.all? { |key, value| object.members[key] == value }

        object.members.merge!(updates)
        store.commit(object)
      end
    end
  end
end
