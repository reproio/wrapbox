require 'yaml'
require 'wrapbox/configuration'

module Wrapbox
  class ConfigRepository
    def initialize
      @configs = {}
    end

    def load_yaml(yaml_file)
      file = ERB.new(File.read(yaml_file)).result
      configs = if Gem::Version.new(Psych::VERSION) >= Gem::Version.new("4.0.0")
        YAML.load(file, aliases: true)
      else
        YAML.load(file)
      end
      configs.each do |name, configuration|
        load_config(name, configuration.merge("name" => name))
      end
    end

    def load_config(name, configuration)
      @configs[name.to_sym] = Configuration.load_config(configuration)
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
