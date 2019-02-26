require File.expand_path(File.dirname(__FILE__) + '/spec_helper')
require 'yaml'
require 'pry'

describe EuCentralBank do
  let(:current_date) { Date.new(2018, 06, 11) }
  let(:historical_date) { Date.new(2018, 03, 14) }

  before do
    @bank = EuCentralBank.new
    @dir_path = File.dirname(__FILE__)

    @current_exchange_rates_xml = File.expand_path(@dir_path + '/fixtures/current_exchange_rates.xml')
    @historical_exchange_rate_xml = File.expand_path(@dir_path + '/fixtures/historical_exchange_rates.xml')

    @tmp_cache_path = File.expand_path(@dir_path + '/tmp/exchange_rates.xml')
    @tmp_history_cache_path = File.expand_path(@dir_path + '/tmp/exchange_rates_90_day.xml')
    yml_cache_path = File.expand_path(@dir_path + '/exchange_rates.yml')
    @exchange_rates = YAML.load_file(yml_cache_path)
  end

  after do
    [@tmp_cache_path, @tmp_history_cache_path].each do |file_name|
      if File.exist? file_name
        File.delete file_name
      end
    end
  end

  describe 'should update itself with exchange rates from ecb website' do
    it 'requests timeframe current' do
      stub_const('EuCentralBank::ECB_RATES_URL', @current_exchange_rates_xml)
      @bank.update_exchange_rates(timeframe: :current)
      EuCentralBank::CURRENCIES.each do |currency|
        expect(@bank.get_rate('EUR', currency, current_date)).to be_a(BigDecimal)
      end
    end

    it 'requests timeframe last_90_days' do
      stub_const('EuCentralBank::ECB_90_DAY_URL', @historical_exchange_rate_xml)
      @bank.update_exchange_rates(timeframe: :last_90_days)
      EuCentralBank::CURRENCIES.each do |currency|
        expect(@bank.get_rate('EUR', currency, historical_date)).to be_a(BigDecimal)
      end
    end

    it 'requests timeframe all' do
      stub_const('EuCentralBank::ECB_ALL_URL', @historical_exchange_rate_xml)
      @bank.update_exchange_rates(timeframe: :all)
      EuCentralBank::CURRENCIES.each do |currency|
        expect(@bank.get_rate('EUR', currency, historical_date)).to be_a(BigDecimal)
      end
    end

    it 'requests an invalid timeframe' do
      expect do
        @bank.update_exchange_rates
      end.to raise_error(
        EuCentralBank::Errors::InvalidTimeframe,
        'Please use :current, :last_90_days or :all'
      )
    end
  end

  it 'should update itself with exchange rates from xml file' do
    @bank.update_exchange_rates(file: @current_exchange_rates_xml)
    EuCentralBank::CURRENCIES.each do |currency|
      expect(@bank.get_rate('EUR', currency, current_date)).to be_a(BigDecimal)
    end
  end

  it 'should set last_updated when the rates are downloaded' do
    lu1 = @bank.last_updated
    @bank.update_exchange_rates(file: @current_exchange_rates_xml)
    lu2 = @bank.last_updated
    sleep(0.01)
    @bank.update_exchange_rates(file: @current_exchange_rates_xml)
    lu3 = @bank.last_updated

    expect(lu1).not_to eq(lu2)
    expect(lu2).not_to eq(lu3)
  end

  it 'should set rates_updated_at when the rates are downloaded' do
    lu1 = @bank.rates_updated_at
    @bank.update_exchange_rates(file: @current_exchange_rates_xml)
    lu2 = @bank.rates_updated_at

    expect(lu1).not_to eq(lu2)
  end

  it "should return the correct exchange rates using exchange" do
    @bank.update_exchange_rates(file: @current_exchange_rates_xml)
    EuCentralBank::CURRENCIES.each do |currency|
      subunit_to_unit  = Money::Currency.wrap(currency).subunit_to_unit
      exchanged_amount = @bank.exchange(100, "EUR", currency, current_date)
      expect(exchanged_amount.cents).to eq((@exchange_rates["currencies"][currency] * subunit_to_unit).round(0).to_i)
    end
  end

  describe '#exchange_with' do
    let(:money) { Money.new(100, 'EUR') }

    it 'should return the correct exchange rates using exchange_with' do
      @bank.update_exchange_rates(file: @current_exchange_rates_xml)
      EuCentralBank::CURRENCIES.each do |currency|
        subunit_to_unit  = Money::Currency.wrap(currency).subunit_to_unit
        amount_from_rate = (@exchange_rates["currencies"][currency] * subunit_to_unit).round(0).to_i

        expect(@bank.exchange_with(Money.new(100, "EUR"), currency, current_date).cents).to eq(amount_from_rate)
      end
    end

    it 'raises Money::Bank::UnknownRate if rates for a specific date are not available' do
      ['2017-02-22', Date.new(2017, 02, 22)].each do |date|
        expect do
          @bank.exchange_with(money, 'USD', date)
        end.to raise_error(Money::Bank::UnknownRate, "No conversion rate known for 'EUR' -> 'USD' on 2017-02-22")
      end
    end
  end

  it "should return the correct exchange rates using last 90 days exchange rates" do
    yml_path = File.expand_path(File.dirname(__FILE__) + '/historical_exchange_rates.yml')
    historical_exchange_rates = YAML.load_file(yml_path)

    @bank.update_exchange_rates(file: @historical_exchange_rate_xml)

    EuCentralBank::CURRENCIES.each do |currency|
      subunit_to_unit  = Money::Currency.wrap(currency).subunit_to_unit
      exchanged_amount = @bank.exchange(100, "EUR", currency, "2018-05-11")
      expect(exchanged_amount.cents).to eq((historical_exchange_rates["currencies"][currency] * subunit_to_unit).round(0).to_i)
    end
  end

  it "should #update_parsed_rates atomically" do
    even_rates = File.expand_path(File.dirname(__FILE__) + '/even_exchange_rates.xml')
    odd_rates = File.expand_path(File.dirname(__FILE__) + '/odd_exchange_rates.xml')

    odd_thread = Thread.new do
      while true; @bank.update_exchange_rates(file: odd_rates); end
    end

    even_thread = Thread.new do
      while true; @bank.update_exchange_rates(file: even_rates); end
    end

    # Updating bank rates so that we're sure the test won't fail prematurely
    # (i.e. even without odd_thread/even_thread getting a change to run)
    @bank.update_exchange_rates(file: odd_rates)

    10.times do
      rates = YAML.load(@bank.export_rates(:yaml))
      rates = rates.values[0].map{ |hash| hash[:rate].to_i }
      expect(rates.length).to eq(31)
      expect(rates).to satisfy { |rts|
        rts.all?(&:even?) || rts.all?(&:odd?)
      }
    end
    even_thread.kill
    odd_thread.kill
  end

  describe 'export / import rates' do
    let(:other_bank) { EuCentralBank.new }

    before do
      @bank.update_exchange_rates(file: @current_exchange_rates_xml)
    end

    it 're-imports JSON' do
      raw_rates = @bank.export_rates(:json)
      other_bank.import_rates(:json, raw_rates)

      expect(@bank.store.send(:index)).to eq(other_bank.store.send(:index))
    end

    it 're-imports Marshalled ruby' do
      raw_rates = @bank.export_rates(:ruby)
      other_bank.import_rates(:ruby, raw_rates)

      expect(@bank.store.send(:index)).to eq(other_bank.store.send(:index))
    end

    it 're-imports YAML' do
      raw_rates = @bank.export_rates(:yaml)
      other_bank.import_rates(:yaml, raw_rates)

      expect(@bank.store.send(:index)).to eq(other_bank.store.send(:index))
    end
  end


  it "should exchange money atomically" do
    # NOTE: We need to introduce an artificial delay in the core get_rate
    # function, otherwise it will take a lot of iterations to hit some sort or
    # 'race-condition'
    Money::Bank::VariableExchange.class_eval do
      alias_method :get_rate_original, :get_rate
      def get_rate(*args)
        sleep(Random.rand)
        get_rate_original(*args)
      end
    end
    even_rates = File.expand_path(File.dirname(__FILE__) + '/even_exchange_rates.xml')
    odd_rates = File.expand_path(File.dirname(__FILE__) + '/odd_exchange_rates.xml')

    odd_thread = Thread.new do
      while true; @bank.update_exchange_rates(file: odd_rates); end
    end

    even_thread = Thread.new do
      while true; @bank.update_exchange_rates(file: even_rates); end
    end

    # Updating bank rates so that we're sure the test won't fail prematurely
    # (i.e. even without odd_thread/even_thread getting a change to run)
    @bank.update_exchange_rates(file: odd_rates)

    10.times do
      expect(@bank.exchange(100, 'INR', 'INR', Date.new(2010, 04, 20)).fractional).to eq(100)
    end
    even_thread.kill
    odd_thread.kill
  end

  it "should raise an error when currency is not available in currency list" do
    expect {
      @bank.get_rate(EuCentralBank::CURRENCIES.first, 'CLP', current_date)
    }.to raise_exception(EuCentralBank::Errors::CurrencyUnavailable)
    expect {
      @bank.get_rate('CLP', EuCentralBank::CURRENCIES.first, current_date)
    }.to raise_exception(EuCentralBank::Errors::CurrencyUnavailable)
    expect {
      @bank.get_rate('ARG', 'CLP', current_date)
    }.to raise_exception(EuCentralBank::Errors::CurrencyUnavailable)
    expect {
      @bank.get_rate('CLP', 'ARG', current_date)
    }.to raise_exception(EuCentralBank::Errors::CurrencyUnavailable)
  end

  it "should not fail when calculating rate from historical base rates" do
    @bank.update_exchange_rates(file: @historical_exchange_rate_xml)

    workday = Date.new(2018, 06, 06)

    expect {
      @bank.exchange(100, 'GBP', 'EUR', workday)
    }.not_to raise_error
  end

	it "should accept a different store" do
		store = double
		bank = EuCentralBank.new(store)
    expect(bank.store).to eq store
	end
end
