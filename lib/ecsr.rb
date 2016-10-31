module Ecsr
  CLASS_NAME_ENV = "ECSR_CLASS_NAME".freeze
  METHOD_NAME_ENV = "ECSR_METHOD_NAME".freeze
  METHOD_ARGS_ENV = "ECSR_METHOD_ARGS".freeze

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
  end
end

require "ecsr/version"

require "ecsr/config_repository"
require "ecsr/configuration"
require "ecsr/job"
