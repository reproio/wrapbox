module Wrapbox
  CLASS_NAME_ENV = "WRAPBOX_CLASS_NAME".freeze
  METHOD_NAME_ENV = "WRAPBOX_METHOD_NAME".freeze
  METHOD_ARGS_ENV = "WRAPBOX_METHOD_ARGS".freeze

  class << self
    def load_config(filename)
      configs.load_yaml(filename)
    end

    def configs
      @configs ||= ConfigRepository.new
    end

    def configure
      yield configs
    end

    def run(*args, runner: nil, config_name: nil, **options)
      config = @configs.get(config_name)
      config.run(*args, **options)
    end

    def run_cmd(*args, runner: nil, config_name: nil, **options)
      config = @configs.get(config_name)
      config.run_cmd(*args, **options)
    end
  end
end

require "wrapbox/version"

require "wrapbox/config_repository"
require "wrapbox/configuration"
require "wrapbox/job"
