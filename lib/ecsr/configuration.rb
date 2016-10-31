require "active_support/core_ext/hash"
require "active_support/core_ext/string"

module Ecsr
  Configuration = Struct.new(
    :name,
    :runner,
    :cluster,
    :region,
    :container_definition,
    :additional_container_definitions,
    :task_role_arn,
    :use_sudo,
    :rm
  ) do
    def self.load_config(config)
      new(
        config["name"],
        config["runner"] ? config["runner"].to_sym : :docker,
        config["cluster"],
        config["region"],
        config["container_definition"].deep_symbolize_keys,
        config["additional_container_definitions"] || [],
        config["task_role_arn"],
        config["use_sudo"].nil? ? false : config["use_sudo"],
        config["rm"].nil? ? false : config["rm"]
      )
    end

    AVAILABLE_RUNNERS = %i(docker ecs)

    def initialize(*args)
      super
      raise "#{runner} is unsupported runner" unless AVAILABLE_RUNNERS.include?(runner)
      require "ecsr/runner/#{runner}"
    end

    def build_runner
      Ecsr::Runner.const_get(runner.to_s.camelcase).new(to_h)
    end

    def run(class_name, method_name, args, **options)
      build_runner.run(class_name, method_name, args, **options)
    end
  end
end
