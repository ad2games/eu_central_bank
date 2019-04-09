# frozen_string_literal: true

require 'open-uri'
require 'nokogiri'
require 'money'
require 'money/rates_store/store_with_historical_data_support'
require 'eu_central_bank/errors'
require 'eu_central_bank/xml_parser'

# rubocop:disable Metrics/ClassLength
class EuCentralBank < Money::Bank::VariableExchange
  attr_accessor :last_updated
  attr_accessor :rates_updated_at

  CURRENCIES = %w[USD JPY BGN CZK DKK GBP HUF ILS ISK PLN RON SEK CHF NOK HRK RUB TRY AUD BRL CAD
                  CNY HKD IDR INR KRW MXN MYR NZD PHP SGD THB ZAR].map(&:freeze).freeze
  ECB_RATES_URL = 'https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml'
  ECB_90_DAY_URL = 'https://www.ecb.europa.eu/stats/eurofxref/eurofxref-hist-90d.xml'
  ECB_ALL_URL = 'https://www.ecb.europa.eu/stats/eurofxref/eurofxref-hist.xml'

  def initialize(store = nil, currencies: nil, &block)
    store      ||= Money::RatesStore::StoreWithHistoricalDataSupport.new
    currencies ||= EuCentralBank::CURRENCIES

    super(store, &block)

    @requested_currencies = currencies
    @currency_string = nil
  end

  def update_exchange_rates(timeframe: nil, file: nil)
    update_parsed_rates(
      parse_xml(
        open(file ? file : url_for_timeframe(timeframe))
      )
    )
  end

  def url_for_timeframe(timeframe)
    case timeframe
    when :current
      ECB_RATES_URL
    when :last_90_days
      ECB_90_DAY_URL
    when :all
      ECB_ALL_URL
    else
      raise Errors::InvalidTimeframe, 'Please use :current, :last_90_days or :all'
    end
  end

  def exchange(cents, from_currency, to_currency, date)
    exchange_with(Money.new(cents, from_currency), to_currency, date)
  end

  # rubocop:disable Metrics/MethodLength
  def exchange_with(from, to_currency, date)
    from_base_rate = nil
    to_base_rate = nil
    rate = get_rate(from.currency, to_currency, date)

    unless rate
      store.transaction true do
        from_base_rate = get_rate('EUR', from.currency.to_s, date)
        to_base_rate = get_rate('EUR', to_currency, date)
      end

      unless from_base_rate && to_base_rate
        raise Money::Bank::UnknownRate, 'No conversion rate known for ' \
          "'#{from.currency.iso_code}' -> '#{to_currency}' on #{date}"
      end

      rate = to_base_rate / from_base_rate
    end

    calculate_exchange(from, to_currency, rate)
  end
  # rubocop:enable Metrics/MethodLength

  def get_rate(from, to, date)
    return 1 if from == to

    check_currency_available(from)
    check_currency_available(to)

    # Backwards compatibility for the opts hash
    date = date[:date] if date.is_a?(Hash)

    store.get_rate(
      ::Money::Currency.wrap(from).iso_code,
      ::Money::Currency.wrap(to).iso_code,
      date
    )
  end

  def set_rate(from, to, rate, date)
    # Backwards compatibility for the opts hash
    date = date[:date] if date.is_a?(Hash)

    store.add_rate(
      ::Money::Currency.wrap(from).iso_code,
      ::Money::Currency.wrap(to).iso_code,
      rate,
      date
    )
  end

  def rates
    store.each_rate.each_with_object({}) do |(from, to, rate, date), hash|
      hash[date] ||= []
      hash[date] << { from: from, to: to, rate: rate }
    end
  end

  def save_rates(file_path, url = ECB_RATES_URL)
    raise Errors::InvalidFilePath unless file_path

    File.open(file_path, 'w') do |file|
      io = open(url)
      io.each_line { |line| file.puts line }
    end
  end

  # rubocop:disable Metrics/MethodLength
  def export_rates(format)
    raise Money::Bank::UnknownRateFormat unless RATE_FORMATS.include? format

    store.transaction true do
      case format
      when :json
        JSON.dump(rates)
      when :ruby
        Marshal.dump(rates)
      when :yaml
        YAML.dump(rates)
      end
    end
  end
  # rubocop:enable Metrics/MethodLength

  def import_rates(content)
    store.transaction true do
      parse_import(content).each do |date, exchange_rates|
        exchange_rates.each do |exchange_rate|
          update_store(exchange_rate, date)
        end
      end
    end

    self
  end

  def check_currency_available(currency)
    currency_string = currency.to_s

    return true if currency_string == 'EUR'
    return true if CURRENCIES.include?(currency_string)

    raise Errors::CurrencyUnavailable, "No rates available for #{currency_string}"
  end

  protected

  def update_store(exchange_rate, date)
    store.add_rate(
      exchange_rate.fetch(:from),
      exchange_rate.fetch(:to),
      BigDecimal(exchange_rate.fetch(:rate)),
      date
    )
  end

  # rubocop:disable Metrics/MethodLength
  def parse_import(content)
    JSON.parse(content, symbolize_names: true)
  rescue JSON::ParserError
    begin
      YAML.load(content) # rubocop:disable Security/YAMLLoad
    rescue Psych::SyntaxError
      begin
        Marshal.load(content)
      rescue TypeError
        raise Money::Bank::UnknownRateFormat
      end
    end
  end
  # rubocop:enable Metrics/MethodLength

  def parse_xml(io)
    parser_document = XmlParser.new
    parser = Nokogiri::XML::SAX::Parser.new(parser_document)
    parser.parse(io)
    parser_document
  end

  def update_parsed_rates(parsed_xml)
    store.transaction true do
      parsed_xml.rates.each do |date, exchange_rates|
        exchange_rates.each do |currency, exchange_rate|
          next unless @requested_currencies.include?(currency)

          set_rate('EUR', currency, BigDecimal(exchange_rate), date)
        end
      end
    end

    @rates_updated_at = parsed_xml.updated_at
    @last_updated = Time.now
  end

  private

  def calculate_exchange(from, to_currency, rate)
    to_currency_money = Money::Currency.wrap(to_currency).subunit_to_unit
    from_currency_money = from.currency.subunit_to_unit
    decimal_money = BigDecimal(to_currency_money) / BigDecimal(from_currency_money)
    money = (decimal_money * from.cents * rate).round
    Money.new(money, to_currency)
  end
end
# rubocop:enable Metrics/ClassLength
