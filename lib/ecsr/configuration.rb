require "aws-sdk"
require "active_support/core_ext/hash"
require "multi_json"

module Ecsr
  Configuration = Struct.new(:name, :cluster, :auto_scaling_group, :region, :container_definition, :additional_container_definitions, :task_role_arn) do
    def self.load_config(config)
      new(
        config["name"],
        config["cluster"],
        config["auto_scaling_group"],
        config["region"],
        config["container_definition"].deep_symbolize_keys,
        config["additional_container_definitions"] || [],
        config["task_role_arn"]
      )
    end

    def task_definition_name
      "ecsr_#{name}"
    end

    def run(class_name, method_name, args, container_definition_overrides: {}, environments: [], task_role_arn: nil, cluster: nil, auto_scaling_group: nil, timeout: nil)
      task_definition = register_task_definition(container_definition_overrides)
      run_task(
        task_definition.task_definition_arn, class_name, method_name, args,
        environments: environments,
        task_role_arn: task_role_arn,
        cluster: cluster,
        auto_scaling_group: auto_scaling_group,
        timeout: timeout
      )
    end

    def register_task_definition(container_definition_overrides)
      definition = container_definition
        .merge(container_definition_overrides)
        .merge(name: task_definition_name)
      container_definitions = [definition, *additional_container_definitions]
      client.register_task_definition({
        family: task_definition_name,
        container_definitions: container_definitions,
      }).task_definition
    end

    def run_task(task_definition_arn, class_name, method_name, args, environments: [], task_role_arn: nil, cluster: nil, timeout: nil, auto_scaling_group: nil)
      cl = cluster || self.cluster
      args = Array(args)

      task = client
        .run_task(build_run_task_options(class_name, method_name, args, environments, cluster, task_definition_arn, task_role_arn))
        .tasks[0]

      begin
        client.wait_until(:tasks_stopped, cluster: cl, tasks: [task.task_arn]) do |w|
          if timeout
            w.max_attempts = (timeout / w.delay).to_i + 1
          end
        end
      rescue Aws::Waiters::Errors::TooManyAttemptsError
        client.stop_task({
          cluster: cluster || self.cluster,
          task: task.task_arn,
          reason: "process timeout",
        })
      end

      task = client.describe_tasks(cluster: cl, tasks: [task.task_arn]).tasks[0]
      container = task.containers.find { |c| c.name = task_definition_name }
      unless container.exit_code == 0
        raise "Container #{task_definition_name} is failed. exit_code=#{container.exit_code}"
      end
    end

    private

    def client
      return @client if @client

      options = {}
      options[:region] = region if region
      @client = Aws::ECS::Client.new(options)
    end

    def build_run_task_options(class_name, method_name, args, environments, cluster, task_definition_arn, task_role_arn)
      environment = environments + [
        {
          name: CLASS_NAME_ENV,
          value: class_name.to_s,
        },
        {
          name: METHOD_NAME_ENV,
          value: method_name.to_s,
        },
        {
          name: METHOD_ARGS_ENV,
          value: MultiJson.dump(args),
        },
      ]
      overrides = {
        container_overrides: [
          {
            name: task_definition_name,
            command: ["bundle", "exec", "rake", "ecsr:run"],
            environment: environment,
          }
        ]
      }
      role_arn = task_role_arn || self.task_role_arn
      overrides[:task_role_arn] = role_arn if role_arn

      {
        cluster: cluster || self.cluster,
        task_definition: task_definition_arn,
        overrides: overrides,
        started_by: "ecsr-#{Ecsr::VERSION}",
      }
    end
  end
end
