module Wrapbox
  CLASS_NAME_ENV = "WRAPBOX_CLASS_NAME".freeze
  METHOD_NAME_ENV = "WRAPBOX_METHOD_NAME".freeze
  METHOD_ARGS_ENV = "WRAPBOX_METHOD_ARGS".freeze

  class << self
    def configs
      @configs ||= ConfigRepository.new
    end

    def configure
      yield configs
    end

    def run(*args, config_name: nil, **options)
      config = @configs.get(config_name)
      config.run(*args, **options)
    end

    def run_cmd(*args, config_name: nil, **options)
      config = @configs.get(config_name)
      config.run_cmd(*args, **options)
    end
  end
end

require "wrapbox/version"

require "wrapbox/config_repository"
require "wrapbox/configuration"
require "wrapbox/job"
