require "active_support/core_ext/hash"

module Ecsr
  Configuration = Struct.new(:name, :cluster, :auto_scaling_group, :region, :container_definition, :additional_container_definitions) do
    def self.load_config(config)
      new(
        config["name"],
        config["cluster"],
        config["auto_scaling_group"],
        config["region"],
        config["container_definition"].deep_symbolize_keys,
        config["additional_container_definitions"]
      )
    end

    def task_definition_name
      "ecsr_#{name}"
    end

    def run(class_name, method_name, args, container_definition_overrides: {}, environments: [], task_role_arn: nil, cluster: nil, auto_scaling_group: nil, launch_timeout: nil, process_timeout: nil)
      task_definition = register_task_definition(container_definition_overrides)
      run_task(
        task_definition.task_definition_arn, class_name, method_name, args,
        environments: environments,
        task_role_arn: task_role_arn,
        cluster: cluster,
        auto_scaling_group: auto_scaling_group,
        launch_timeout: launch_timeout,
        process_timeout: process_timeout
      )
    end

    def register_task_definition(container_definition_overrides)
      definition = container_definition.merge(container_definition_overrides)
      container_definitions = [definition, *additional_container_definitions]
      client.register_task_definition({
        family: task_definition_name,
        container_definitions: container_definitions.merge(name: task_definition_name),
      }).task_definition
    end

    def run_task(task_definition_arn, class_name, method_name, args, environments: [], task_role_arn: nil, cluster: nil, launch_timeout: nil, process_timeout: nil, auto_scaling_group: nil)
      task = client
        .run_task(build_run_task_options(class_name, method_name, args, environments, cluster, task_definition_arn))
        .tasks[0]
      begin
        client.wait_until(:tasks_running, tasks: [task.task_arn]) do |w|
          if launch_timeout
            w.max_attempts = (launch_timeout / w.delay).to_i + 1
          end
        end
      rescue Aws::Waiters::Errors::WaiterFailed
        client.stop_task({
          cluster: cluster || self.cluster,
          task: task.task_arn,
          reason: "launch timeout",
        })
      end

      client.wait_until(:tasks_stopped, tasks: [task.task_arn]) do |w|
        if process_timeout
          w.max_attempts = (process_timeout / w.delay).to_i + 1
        end
      end

      task = client.describe_tasks(tasks: [task.task_arn]).tasks[0]
      container = task.containers.find { |c| c.name = task_definition_name }
      unless container.exit_code == 0
        raise "Container #{task_definition_name} is failed. exit_code=#{container.exit_code}"
      end
    end

    def client
      return @client if @client

      options = {}
      options[:region] = region if region
      @client = Aws::ECS::Client.new(options)
    end

    private

    def build_run_task_options(class_name, method_name, args, environments, cluster, task_definition_arn)
      environment = environments + [
        {
          name: CLASS_NAME_ENV,
          value: class_name,
        },
        {
          name: METHOD_NAME_ENV,
          value: method_name,
        },
        {
          name: METHOD_ARGS_ENV,
          value: serialize(args),
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
      overrides[:task_role_arn] = task_role_arn if task_role_arn

      {
        cluster: cluster || self.cluster,
        task_definition: task_definition_arn,
        overrides: overrides,
        started_by: "ecsr-#{Ecsr::VERSION}",
      }
    end
  end
end
