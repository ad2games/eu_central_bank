# frozen_string_literal: true

class EuCentralBank < Money::Bank::VariableExchange
  class XmlParser < Nokogiri::XML::SAX::Document
    attr_reader :rates
    attr_reader :updated_at

    def initialize
      @rates = {}
      @updated_at = nil
      @current_date = nil
    end

    # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
    def start_element(name, attributes = [])
      return if name != 'Cube' || attributes.empty?

      first_name, first_value = attributes[0]

      case first_name
      when 'time'
        @current_date = Time.parse(first_value).to_date
        @updated_at ||= @current_date
        @rates[@current_date] = []
      when 'currency'
        currency = first_value
        _, rate = attributes[1]
        @rates[@current_date] << [currency, rate]
      end
    rescue StandardError => e
      raise Nokogiri::XML::XPath::SyntaxError, e.message
    end
    # rubocop:enable Metrics/MethodLength, Metrics/AbcSize

    def end_document
      raise EuCentralBank::Errors::FileContentMissing if @rates.empty? || @updated_at.nil?
    end
  end
end
