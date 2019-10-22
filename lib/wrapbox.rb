require "logger"

module Wrapbox
  CLASS_NAME_ENV = "WRAPBOX_CLASS_NAME".freeze
  METHOD_NAME_ENV = "WRAPBOX_METHOD_NAME".freeze
  METHOD_ARGS_ENV = "WRAPBOX_METHOD_ARGS".freeze

  class << self
    attr_accessor :logger

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
      get_config(config_name).run(*args, **options)
    end

    def run_cmd(*args, runner: nil, config_name: nil, **options)
      get_config(config_name).run_cmd(*args, **options)
    end

    private

    def get_config(config_name)
      @configs.get(config_name) or
        raise RuntimeError, %Q{The configuration "#{config_name}" is not registered}
    end
  end

  $stdout.sync = true
  self.logger = Logger.new($stdout)
  self.logger.level = :info
end

require "wrapbox/version"

require "wrapbox/config_repository"
require "wrapbox/configuration"
require "wrapbox/job"
