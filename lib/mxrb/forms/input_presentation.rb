# frozen_string_literal: true

module Mxrb
  module Forms
    # Shared by the Mendix compiler and the independent Ruby web projection.
    module InputPresentation
      AUTOCOMPLETE_PURPOSES = {
        'FullName' => 'name', 'HonorificPrefix' => 'honorific-prefix', 'GivenName' => 'given-name',
        'AdditionalName' => 'additional-name', 'FamilyName' => 'family-name',
        'HonorificSuffix' => 'honorific-suffix', 'JobTitle' => 'organization-title',
        'CompanyName' => 'organization', 'StreetAddress' => 'street-address',
        'StreetAddressLine1' => 'address-line1', 'StreetAddressLine2' => 'address-line2',
        'StreetAddressLine3' => 'address-line3', 'AddressLevel4' => 'address-level4',
        'AddressLevel3' => 'address-level3', 'AddressLevel2' => 'address-level2',
        'AddressLevel1' => 'address-level1', 'CountryCode' => 'country',
        'CountryName' => 'country-name', 'PostalCode' => 'postal-code',
        'CreditCardFullName' => 'cc-name', 'CreditCardGivenName' => 'cc-given-name',
        'CreditCardAdditionalName' => 'cc-additional-name',
        'CreditCardFamilyName' => 'cc-family-name', 'CreditCardNumber' => 'cc-number',
        'CreditCardExpiration' => 'cc-exp', 'CreditCardExpirationMonth' => 'cc-exp-month',
        'CreditCardExpirationYear' => 'cc-exp-year', 'CreditCardSecurityCode' => 'cc-csc',
        'CreditCardType' => 'cc-type', 'TransactionCurrency' => 'transaction-currency',
        'TransactionAmount' => 'transaction-amount', 'Birthday' => 'bday',
        'DayOfBirth' => 'bday-day', 'MonthOfBirth' => 'bday-month', 'YearOfBirth' => 'bday-year',
        'TelephoneNumber' => 'tel', 'TelephoneCountryCode' => 'tel-country-code',
        'TelephoneWithoutCountryCode' => 'tel-national', 'TelephoneAreaCode' => 'tel-area-code',
        'TelephoneLocal' => 'tel-local', 'TelephoneLocalPrefix' => 'tel-local-prefix',
        'TelephoneLocalSuffix' => 'tel-local-suffix', 'TelephoneExtension' => 'tel-extension',
        'InstantMessageProtocol' => 'impp'
      }.freeze

      def self.autocomplete(widget)
        return 'off' unless widget.fetch('Autocomplete', true)

        purpose = widget.fetch('AutocompletePurpose', 'On').to_s
        AUTOCOMPLETE_PURPOSES.fetch(purpose) do
          purpose.gsub(/([a-z\d])([A-Z])/, '\\1-\\2').downcase
        end
      end
    end
  end
end
