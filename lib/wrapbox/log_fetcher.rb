require "active_support/core_ext/string"

module Wrapbox
  module LogFetcher
    def self.new(type, **options)
      raise "log_fetcher config needs `type`" unless type
      require "wrapbox/log_fetcher/#{type}"
      self.const_get(type.classify).new(**options)
    end
  end
end
