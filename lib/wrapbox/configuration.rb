require "active_support/core_ext/hash"
require "active_support/core_ext/string"

module Wrapbox
  Configuration = Struct.new(
    :name,
    :revision,
    :runner,
    :cluster,
    :region,
    :retry,
    :retry_interval,
    :retry_interval_multiplier,
    :container_definition,
    :additional_container_definitions,
    :task_role_arn,
    :keep_container
  ) do
    def self.load_config(config)
      new(
        config["name"],
        config["revision"],
        config["runner"] ? config["runner"].to_sym : :docker,
        config["cluster"],
        config["region"],
        config["retry"] || 0,
        config["retry_interval"] || 1,
        config["retry_interval_multiplier"] || 2,
        config["container_definition"].deep_symbolize_keys,
        config["additional_container_definitions"] || [],
        config["task_role_arn"],
        config["keep_container"]
      )
    end

    AVAILABLE_RUNNERS = %i(docker ecs)

    def initialize(*args)
      super
      raise "#{runner} is unsupported runner" unless AVAILABLE_RUNNERS.include?(runner)
      require "wrapbox/runner/#{runner}"
    end

    def build_runner
      Wrapbox::Runner.const_get(runner.to_s.camelcase).new(to_h)
    end

    def run(class_name, method_name, args, **options)
      build_runner.run(class_name, method_name, args, **options)
    end

    def run_cmd(*cmd, **options)
      build_runner.run_cmd(*cmd, **options)
    end
  end
end
