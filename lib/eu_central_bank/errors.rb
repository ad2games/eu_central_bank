class EuCentralBank < Money::Bank::VariableExchange
  module Errors
    class CurrencyUnavailable < StandardError; end
    class InvalidCache < StandardError; end
    class InvalidTimeframe < StandardError; end
  end
end
