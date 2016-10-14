require "multi_json"

module Ecsr
  module Runner
    def self.run
      klass = ENV[CLASS_NAME_ENV].constantize
      method_name = ENV[METHOD_NAME_ENV].to_sym
      args = MultiJson.load(ENV[METHOD_ARGS_ENV])

      klass.new.send(method_name, *args)
    end
  end
end
