require "aws-sdk"
require "multi_json"
require "thor"
require "yaml"
require "active_support/core_ext/hash"
require "logger"

require "wrapbox/config_repository"
require "wrapbox/version"

module Wrapbox
  module Runner
    class Ecs
      class ExecutionError < StandardError; end
      class LaunchFailure < StandardError; end

      attr_reader \
        :name,
        :revision,
        :cluster,
        :region,
        :container_definition,
        :additional_container_definitions,
        :task_role_arn

      def initialize(options)
        @name = options[:name]
        @revision = options[:revision]
        @cluster = options[:cluster]
        @region = options[:region]
        @container_definition = options[:container_definition]
        @additional_container_definitions = options[:additional_container_definitions]
        @task_role_arn = options[:task_role_arn]
        @logger = Logger.new($stdout)
      end

      def run(class_name, method_name, args, container_definition_overrides: {}, environments: [], task_role_arn: nil, cluster: nil, timeout: 3600 * 24, launch_timeout: 60 * 10, launch_retry: 10, retry_interval: 1, retry_interval_multiplier: 2, max_retry_interval: 120)
        task_definition = register_task_definition(container_definition_overrides)
        run_task(
          task_definition.task_definition_arn, class_name, method_name, args,
          command: ["bundle", "exec", "rake", "wrapbox:run"],
          environments: environments,
          task_role_arn: task_role_arn || @task_role_arn,
          cluster: cluster,
          timeout: timeout,
          launch_timeout: launch_timeout,
          launch_retry: launch_retry,
          retry_interval: retry_interval,
          retry_interval_multiplier: retry_interval_multiplier,
          max_retry_interval: max_retry_interval,
        )
      end

      def run_cmd(*cmd, container_definition_overrides: {}, environments: [], task_role_arn: nil, cluster: nil, timeout: 3600 * 24, launch_timeout: 60 * 10, launch_retry: 10, retry_interval: 1, retry_interval_multiplier: 2, max_retry_interval: 120)
        task_definition = register_task_definition(container_definition_overrides)

        run_task(
          task_definition.task_definition_arn, nil, nil, nil,
          command: cmd,
          environments: environments,
          task_role_arn: task_role_arn,
          cluster: cluster,
          timeout: timeout,
          launch_timeout: launch_timeout,
          launch_retry: launch_retry,
          retry_interval: retry_interval,
          retry_interval_multiplier: retry_interval_multiplier,
          max_retry_interval: max_retry_interval,
        )
      end

      def run_task(task_definition_arn, class_name, method_name, args, command:, environments: [], task_role_arn: nil, cluster: nil, timeout: 3600 * 24, launch_timeout: 60 * 10, launch_retry: 10, retry_interval: 1, retry_interval_multiplier: 2, max_retry_interval: 120)
        cl = cluster || self.cluster
        args = Array(args)

        launch_try_count = 0
        current_retry_interval = retry_interval
        task = nil
        exit_code = nil
        begin
          task = client
            .run_task(build_run_task_options(class_name, method_name, args, command, environments, cluster, task_definition_arn, task_role_arn))
            .tasks[0]
          raise LaunchFailure unless task
          @logger.debug("Create Task: #{task.task_arn}")
          client.wait_until(:tasks_running, cluster: cl, tasks: [task.task_arn]) do |w|
            if launch_timeout
              w.delay = 5
              w.max_attempts = launch_timeout / w.delay
            else
              w.max_attempts = nil
            end
          end
        rescue Aws::Waiters::Errors::TooManyAttemptsError, LaunchFailure
          exit_code = task && fetch_exit_code(cl, task.task_arn)
          unless exit_code
            if launch_try_count >= launch_retry
              client.stop_task(
                cluster: cl,
                task: task.task_arn,
                reason: "launch timeout"
              ) if task
              raise
            else
              put_waiting_task_count_metric(cl)
              launch_try_count += 1
              @logger.debug("Retry Create Task after #{current_retry_interval} sec")
              sleep current_retry_interval
              current_retry_interval = [current_retry_interval * retry_interval_multiplier, max_retry_interval].min
              retry
            end
          end
        rescue Aws::Waiters::Errors::WaiterFailed
          exit_code = task && fetch_exit_code(cl, task.task_arn)
          raise unless exit_code
        end

        @logger.debug("Launch Task: #{task.task_arn}")

        begin
          client.wait_until(:tasks_stopped, cluster: cl, tasks: [task.task_arn]) do |w|
            if timeout
              w.delay = 5
              w.max_attempts = timeout / w.delay
            else
              w.max_attempts = nil
            end
          end
        rescue Aws::Waiters::Errors::TooManyAttemptsError
          client.stop_task({
            cluster: cluster || self.cluster,
            task: task.task_arn,
            reason: "process timeout",
          })
          raise ExecutionError, "process timeout"
        end

        @logger.debug("Stop Task: #{task.task_arn}")

        exit_code ||= fetch_exit_code(cl, task.task_arn)
        unless exit_code == 0
          raise ExecutionError, "Container #{task_definition_name} is failed. exit_code=#{exit_code}"
        end
      end

      private

      def task_definition_name
        "wrapbox_#{name}"
      end

      def fetch_exit_code(cluster, task_arn)
        task = client.describe_tasks(cluster: cluster, tasks: [task_arn]).tasks[0]
        container = task.containers.find { |c| c.name = task_definition_name }
        container.exit_code
      end

      def register_task_definition(container_definition_overrides)
        definition = container_definition
          .merge(container_definition_overrides)
          .merge(name: task_definition_name)
        container_definitions = [definition, *additional_container_definitions]

        if revision
          begin
            return client.describe_task_definition(task_definition: "#{task_definition_name}:#{revision}").task_definition
          rescue
          end
        end

        register_retry_count = 0
        begin
          client.register_task_definition({
            family: task_definition_name,
            container_definitions: container_definitions,
          }).task_definition
        rescue Aws::ECS::Errors::ClientException
          raise if register_retry_count > 2
          register_retry_count += 1
          sleep 2
          retry
        end
      end

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
        @cloud_watch_client = Aws::CloudWatch::Client.new(options)
      end

      def put_waiting_task_count_metric(cluster)
        cloud_watch_client.put_metric_data(
          namespace: "wrapbox",
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

      def build_run_task_options(class_name, method_name, args, command, environments, cluster, task_definition_arn, task_role_arn)
        env = environments
        env += [
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
        ] if class_name && method_name && args
        overrides = {
          container_overrides: [
            {
              name: task_definition_name,
              command: command,
              environment: env,
            },
          ],
        }
        role_arn = task_role_arn || self.task_role_arn
        overrides[:task_role_arn] = role_arn if role_arn

        {
          cluster: cluster || self.cluster,
          task_definition: task_definition_arn,
          overrides: overrides,
          started_by: "wrapbox-#{Wrapbox::VERSION}",
        }
      end

      class Cli < Thor
        namespace :ecs

        desc "run_cmd [shell command]", "Run shell on ECS"
        method_option :config, aliases: "-f", required: true, banner: "YAML_FILE", desc: "yaml file path"
        method_option :config_name, aliases: "-n", required: true, default: "default"
        method_option :cluster, aliases: "-c"
        method_option :environments, aliases: "-e"
        method_option :task_role_arn
        method_option :timeout, type: :numeric
        method_option :launch_timeout, type: :numeric
        method_option :launch_retry, type: :numeric
        method_option :max_retry_interval, type: :numeric
        def run_cmd(*args)
          if args.size == 1
            args = args[0].split(" ")
          end

          repo = Wrapbox::ConfigRepository.new.tap { |r| r.load_yaml(options[:config]) }
          config = repo.get(options[:config_name])
          config.runner = :ecs
          runner = config.build_runner
          environments = options[:environments].to_s.split(/,\s*/).map { |kv| kv.split("=") }.map do |k, v|
            {name: k, value: v}
          end
          run_options = {
            task_role_arn: options[:task_role_arn],
            timeout: options[:timeout],
            launch_timeout: options[:launch_timeout],
            launch_retry: options[:launch_retry],
            max_retry_interval: options[:max_retry_interval]
          }.reject { |_, v| v.nil? }
          runner.run_cmd(*args, environments: environments, **run_options)
        end
      end
    end
  end
end
