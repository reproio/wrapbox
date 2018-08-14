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
    :container_definitions,
    :volumes,
    :placement_constraints,
    :placement_strategy,
    :launch_type,
    :requires_compatibilities,
    :task_definition,
    :additional_container_definitions,
    :network_mode,
    :network_configuration,
    :cpu,
    :memory,
    :task_role_arn,
    :execution_role_arn,
    :keep_container,
    :log_fetcher,
    :group
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
        config["container_definition"]&.deep_symbolize_keys,
        config["container_definitions"]&.map(&:deep_symbolize_keys) || [],
        config["volumes"]&.map(&:deep_symbolize_keys) || [],
        config["placement_constraints"]&.map(&:deep_symbolize_keys) || [],
        config["placement_strategy"]&.map(&:deep_symbolize_keys) || [],
        config["launch_type"],
        config["requires_compatibilities"] || ["EC2"],
        config["task_definition"]&.deep_symbolize_keys,
        config["additional_container_definitions"]&.map(&:deep_symbolize_keys) || [],
        config["network_mode"],
        config["network_configuration"]&.deep_symbolize_keys,
        config["cpu"]&.to_s,
        config["memory"]&.to_s,
        config["task_role_arn"],
        config["execution_role_arn"],
        config["keep_container"],
        config["log_fetcher"]&.deep_symbolize_keys,
        config["group"]
      )
    end

    AVAILABLE_RUNNERS = %i(docker ecs)

    def initialize(*args)
      super
    end

    def build_runner(overrided_runner = nil)
      r = overrided_runner || runner
      raise "#{r} is unsupported runner" unless AVAILABLE_RUNNERS.include?(r.to_sym)
      require "wrapbox/runner/#{r}"
      Wrapbox::Runner.const_get(r.to_s.camelcase).new(to_h)
    end

    def run(class_name, method_name, args, **options)
      build_runner.run(class_name, method_name, args, **options)
    end

    def run_cmd(*cmd, **options)
      build_runner.run_cmd(*cmd, **options)
    end
  end
end
