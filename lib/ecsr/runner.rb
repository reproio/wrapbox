module Ecsr
  module Runner
    def self.run
      klass = ENV[CLASS_NAME_ENV].safe_constantize
      method_name = ENV[METHOD_NAME_ENV].to_sym
      args = deserialize(ENV[METHOD_ARGS_ENV])

      klass.new.send(method_name, *args)
    end
  end
end
