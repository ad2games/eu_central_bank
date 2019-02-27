class EuCentralBank < Money::Bank::VariableExchange
  module Errors
    class CurrencyUnavailable < StandardError; end
    class FileContentMissing < StandardError; end
    class InvalidFilePath < StandardError; end
    class InvalidTimeframe < StandardError; end
  end
end
