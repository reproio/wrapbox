require "aws-sdk"
require "active_support/core_ext/hash"
require "multi_json"

module Ecsr
  Configuration = Struct.new(:name, :cluster, :region, :container_definition, :additional_container_definitions, :task_role_arn) do
    def self.load_config(config)
      new(
        config["name"],
        config["cluster"],
        config["region"],
        config["container_definition"].deep_symbolize_keys,
        config["additional_container_definitions"] || [],
        config["task_role_arn"]
      )
    end

    def task_definition_name
      "ecsr_#{name}"
    end

    def run(class_name, method_name, args, container_definition_overrides: {}, environments: [], task_role_arn: nil, cluster: nil, timeout: 3600 * 24, launch_timeout: 60 * 10, launch_retry: 10)
      task_definition = register_task_definition(container_definition_overrides)
      run_task(
        task_definition.task_definition_arn, class_name, method_name, args,
        environments: environments,
        task_role_arn: task_role_arn,
        cluster: cluster,
        timeout: timeout,
        launch_timeout: launch_timeout,
        launch_retry: launch_retry,
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

    def run_task(task_definition_arn, class_name, method_name, args, environments: [], task_role_arn: nil, cluster: nil, timeout: 3600 * 24, launch_timeout: 60 * 10, launch_retry: 10)
      cl = cluster || self.cluster
      args = Array(args)

      task = client
        .run_task(build_run_task_options(class_name, method_name, args, environments, cluster, task_definition_arn, task_role_arn))
        .tasks[0]

      launch_try_count = 0
      begin
        launched_at = Process.clock_gettime(Process::CLOCK_MONOTONIC, :second)
        client.wait_until(:tasks_running, cluster: cl, tasks: [task.task_arn]) do |w|
          if launch_timeout
            w.max_attempts = nil
            w.before_wait do
              throw :failure if Process.clock_gettime(Process::CLOCK_MONOTONIC, :second) - launched_at > launch_timeout
            end
          end
        end
      rescue Aws::Waiters::Errors::TooManyAttemptsError
        if launch_try_count >= launch_retry
          client.stop_task(
            cluster: cl,
            task: task.task_arn,
            reason: "launch timeout"
          )
          raise
        else
          put_waiting_task_count_metric(cl)
          launch_try_count += 1
          retry
        end
      rescue Aws::Waiters::Errors::WaiterFailed
      end

      begin
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC, :second)
        client.wait_until(:tasks_stopped, cluster: cl, tasks: [task.task_arn]) do |w|
          if timeout
            w.max_attempts = nil
            w.before_wait do
              throw :failure if Process.clock_gettime(Process::CLOCK_MONOTONIC, :second) - started_at > timeout
            end
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

    def cloud_watch_client
      return @cloud_watch_client if @cloud_watch_client

      options = {}
      options[:region] = region if region
      @cloud_watch_client = Aws::CloudWatch::Client.new
    end

    def put_waiting_task_count_metric(cluster)
      cloud_watch_client.put_metric_data(
        namespace: "ecsr",
        metric_data: [
          metric_name: "WaitingTaskCount",
          dimensions: [
            {
              name: "ClusterName",
              value: cluster || self.cluster,
            },
          ],
          value: 1.0,
          unit: "Count",
        ]
      )
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
