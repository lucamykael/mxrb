# frozen_string_literal: true

module Mxrb
  module Protocols
    # Immutable connector identity backed by a real fixture, official package,
    # or verifiable official metadata. No identifier is inferred from a name.
    Entry = Data.define(
      :protocol, :name, :publisher, :category, :marketplace_id,
      :content_type, :module_name, :appstore_guids, :certified_version,
      :certified_version_id, :certified_sha256, :certified_model_version,
      :source_url, :evidence_date
    ) do
      def matches_guid?(guid)
        key = guid.to_s
        !key.empty? && appstore_guids.include?(key)
      end

      def matches_lock?(name, data)
        marketplace_id == data['content_id'].to_s && module_name == name.to_s
      end

      def certified_lock?(data)
        certified_version == data['version'].to_s &&
          certified_version_id == data['version_id'].to_s &&
          certified_sha256 == data['sha256'].to_s
      end
    end
  end
end
