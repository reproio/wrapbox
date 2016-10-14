require 'yaml'

module Ecsr
  class ConfigRepository
    def initialize
      @configs = {}
    end

    def load_yaml(yaml_file)
      configs = YAML.load_file(yaml_file)
      configs.each do |name, configuration|
        load_config(name, configuration.merge("name" => name))
      end
    end

    def load_config(name, configuration)
      @configs[name.to_sym] = configuration
    end

    def default
      @configs[:default]
    end

    def get(name)
      name ? @configs[name.to_sym] : default
    end
    alias_method(:[], :get)
  end
end
