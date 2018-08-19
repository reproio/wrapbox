require "active_support/core_ext/string"

# LogFetcher Implementation requires two methods.
# - run (start log fetching asynchronously)
# - stop (stop log fetching)
module Wrapbox
  module LogFetcher
    def self.new(type, **options)
      raise "log_fetcher config needs `type`" unless type
      require "wrapbox/log_fetcher/#{type}"
      self.const_get(type.classify).new(**options)
    end

    def run(task:)
      raise NotImplementedError
    end

    def stop
      raise NotImplementedError
    end
  end
end
