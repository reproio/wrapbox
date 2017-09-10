require "aws-sdk"
require "multi_json"
require "thor"
require "yaml"
require "active_support/core_ext/hash"
require "logger"
require "pp"

require "wrapbox/config_repository"
require "wrapbox/log_fetcher"
require "wrapbox/version"

module Wrapbox
  module Runner
    class Ecs
      class ExecutionFailure < StandardError; end
      class ContainerAbnormalEnd < StandardError; end
      class ExecutionTimeout < StandardError; end
      class LaunchFailure < StandardError; end
      class LackResource < StandardError; end

      EXECUTION_RETRY_INTERVAL = 3
      WAIT_DELAY = 5
      HOST_TERMINATED_REASON_REGEXP = /Host EC2.*terminated/

      attr_reader \
        :name,
        :revision,
        :cluster,
        :region,
        :container_definition,
        :task_definition_name,
        :main_container_name,
        :additional_container_definitions,
        :task_role_arn

      def initialize(options)
        @name = options[:name]
        @revision = options[:revision]
        @cluster = options[:cluster]
        @region = options[:region]

        if options[:container_definition] && options[:task_definition]
          raise "Please set only one of `container_definition` and `task_definition`"
        end
        @container_definition = options[:container_definition]
        @task_definition_info = options[:task_definition]

        if @container_definition
          @task_definition_name = "wrapbox_#{@name}"
          @main_container_name = @container_definition[:name] || @task_definition_name
        elsif @task_definition_info
          @task_definition_name = @task_definition_info[:task_definition_name]
          @main_container_name = @task_definition_info[:main_container_name]
          unless @main_container_name
            raise "Please set `task_definition[:main_container_name]`"
          end
        end

        @additional_container_definitions = options[:additional_container_definitions]
        @task_role_arn = options[:task_role_arn]
        $stdout.sync = true
        @logger = Logger.new($stdout)
        if options[:log_fetcher]
          type = options[:log_fetcher].delete(:type)
          @log_fetcher = LogFetcher.new(type, options[:log_fetcher])
        end
      end

      class Parameter
        attr_reader \
          :environments,
          :task_role_arn,
          :cluster,
          :timeout,
          :launch_timeout,
          :launch_retry,
          :retry_interval,
          :retry_interval_multiplier,
          :max_retry_interval,
          :execution_retry

        def initialize(environments: [], task_role_arn: nil, cluster: nil, timeout: 3600 * 24, launch_timeout: 60 * 10, launch_retry: 10, retry_interval: 1, retry_interval_multiplier: 2, max_retry_interval: 120, execution_retry: 0)
          b = binding
          method(:initialize).parameters.each do |param|
            instance_variable_set("@#{param[1]}", b.local_variable_get(param[1]))
          end
        end
      end

      def run(class_name, method_name, args, container_definition_overrides: {}, **parameters)
        task_definition = prepare_task_definition(container_definition_overrides)
        parameter = Parameter.new(**parameters)

        run_task(
          task_definition.task_definition_arn, class_name, method_name, args,
          ["bundle", "exec", "rake", "wrapbox:run"],
          parameter
        )
      end

      def run_cmd(cmds, container_definition_overrides: {}, **parameters)
        task_definition = prepare_task_definition(container_definition_overrides)

        cmds << nil if cmds.empty?
        ths = cmds.map.with_index do |cmd, idx|
          Thread.new(cmd, idx) do |c, i|
            Thread.current[:cmd_index] = i
            envs = (parameters[:environments] || []) + [{name: "WRAPBOX_CMD_INDEX", value: i.to_s}]
            run_task(
              task_definition.task_definition_arn, nil, nil, nil,
              c&.split(/\s+/),
              Parameter.new(**parameters.merge(environments: envs))
            )
          end
        end
        ths.each(&:join)
      end

      private

      def use_existing_task_definition?
        !!@task_definition_info
      end

      def run_task(task_definition_arn, class_name, method_name, args, command, parameter)
        cl = parameter.cluster || self.cluster
        execution_try_count = 0

        begin
          task = create_task(task_definition_arn, class_name, method_name, args, command, parameter)
          @log_fetcher.run if @log_fetcher

          @logger.debug("Launch Task: #{task.task_arn}")

          wait_task_stopped(cl, task.task_arn, parameter.timeout)

          @logger.debug("Stop Task: #{task.task_arn}")

          # Avoid container exit code fetch miss
          sleep WAIT_DELAY

          task_status = fetch_task_status(cl, task.task_arn)

          # If exit_code is nil, Container is force killed or ECS failed to launch Container by Irregular situation
          error_message = build_error_message(task_definition_name, task.task_arn, task_status)
          raise ContainerAbnormalEnd, error_message unless task_status[:exit_code]
          raise ExecutionFailure, error_message unless task_status[:exit_code] == 0

          true
        rescue ContainerAbnormalEnd
          retry if task_status[:stopped_reason] =~ HOST_TERMINATED_REASON_REGEXP

          if execution_try_count >= parameter.execution_retry
            raise
          else
            execution_try_count += 1
            @logger.debug("Retry Execution after #{EXECUTION_RETRY_INTERVAL} sec")
            sleep EXECUTION_RETRY_INTERVAL
            retry
          end
        ensure
          if @log_fetcher
            begin
              @log_fetcher.stop
              @log_fetcher.join
            rescue => e
              @logger.warn(e)
            end
          end
        end
      end

      def create_task(task_definition_arn, class_name, method_name, args, command, parameter)
        cl = parameter.cluster || self.cluster
        args = Array(args)

        launch_try_count = 0
        current_retry_interval = parameter.retry_interval

        begin
          run_task_options = build_run_task_options(task_definition_arn, class_name, method_name, args, command, cl, parameter.environments, parameter.task_role_arn)
          @logger.debug("Task Options: #{run_task_options}")
          task = client
            .run_task(run_task_options)
            .tasks[0]

          raise LackResource unless task # this case is almost lack of container resource.

          @logger.debug("Create Task: #{task.task_arn}")

          # Wait ECS Task Status becomes stable
          sleep WAIT_DELAY

          begin
            wait_task_running(cl, task.task_arn, parameter.launch_timeout)
            task
          rescue Aws::Waiters::Errors::TooManyAttemptsError
            client.stop_task(
              cluster: cl,
              task: task.task_arn,
              reason: "launch timeout"
            )
            raise
          rescue Aws::Waiters::Errors::WaiterFailed
            task_status = fetch_task_status(cl, task.task_arn)

            case task_status[:last_status]
            when "RUNNING"
              return task
            when "PENDING"
              retry
            else
              if task_status[:exit_code]
                return task
              else
                raise LaunchFailure
              end
            end
          end
        rescue LackResource
          @logger.debug("Failed to create task, because of lack resource")
          put_waiting_task_count_metric(cl)

          if launch_try_count >= parameter.launch_retry
            raise
          else
            launch_try_count += 1
            @logger.debug("Retry Create Task after #{current_retry_interval} sec")
            sleep current_retry_interval
            current_retry_interval = [current_retry_interval * parameter.retry_interval_multiplier, parameter.max_retry_interval].min
            retry
          end
        rescue LaunchFailure
          if launch_try_count >= parameter.launch_retry
            task_status = fetch_task_status(cl, task.task_arn)
            raise LaunchFailure, build_error_message(task_definition_name, task.task_arn, task_status)
          else
            launch_try_count += 1
            @logger.debug("Retry Create Task after #{current_retry_interval} sec")
            sleep current_retry_interval
            current_retry_interval = [current_retry_interval * parameter.retry_interval_multiplier, parameter.max_retry_interval].min
            retry
          end
        end
      end

      def wait_until_with_timeout(cluster, task_arn, timeout, waiter_name)
        client.wait_until(waiter_name, cluster: cluster, tasks: [task_arn]) do |w|
          if timeout
            w.delay = WAIT_DELAY
            w.max_attempts = timeout / w.delay
          else
            w.max_attempts = nil
          end
        end
      end

      def wait_task_running(cluster, task_arn, launch_timeout)
        wait_until_with_timeout(cluster, task_arn, launch_timeout, :tasks_running)
      end

      def wait_task_stopped(cluster, task_arn, execution_timeout)
        wait_until_with_timeout(cluster, task_arn, execution_timeout, :tasks_stopped)
      rescue Aws::Waiters::Errors::TooManyAttemptsError
        client.stop_task({
          cluster: cluster,
          task: task_arn,
          reason: "process timeout",
        })
        raise ExecutionTimeout, "Task #{task_definition_name} is timeout. task=#{task_arn}, timeout=#{execution_timeout}"
      end

      def fetch_task_status(cluster, task_arn)
        task = client.describe_tasks(cluster: cluster, tasks: [task_arn]).tasks[0]
        container = task.containers.find { |c| c.name == main_container_name }
        {
          last_status: task.last_status,
          exit_code: container.exit_code,
          stopped_reason: task.stopped_reason,
          container_stopped_reason: container.reason
        }
      end

      def prepare_task_definition(container_definition_overrides)
        if use_existing_task_definition?
          client.describe_task_definition(task_definition: task_definition_name).task_definition
        else
          register_task_definition(container_definition_overrides)
        end
      end

      def register_task_definition(container_definition_overrides)
        definition = container_definition
          .merge(container_definition_overrides)
          .merge(name: main_container_name)
        container_definitions = [definition, *additional_container_definitions]

        if revision
          begin
            return client.describe_task_definition(task_definition: "#{task_definition_name}:#{revision}").task_definition
          rescue
          end
        end

        @logger.debug("Container Definitions: #{container_definitions}")
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
            timestamp: Time.now,
            value: 1.0,
            unit: "Count",
          ]
        )
      end

      def build_run_task_options(task_definition_arn, class_name, method_name, args, command, cluster, environments, task_role_arn)
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
              name: main_container_name,
              environment: env,
            }.tap { |o| o[:command] = command if command },
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

      def build_error_message(task_definition_name, task_arn, task_status)
        error_message = "Task #{task_definition_name} is failed. task=#{task_arn}, "
        error_message << "cmd_index=#{Thread.current[:cmd_index]}, " if Thread.current[:cmd_index]
        error_message << "exit_code=#{task_status[:exit_code]}, task_stopped_reason=#{task_status[:stopped_reason]}, container_stopped_reason=#{task_status[:container_stopped_reason]}"
        error_message
      end

      class Cli < Thor
        namespace :ecs

        desc "run_cmd [shell command]", "Run shell on ECS"
        method_option :config, aliases: "-f", required: true, banner: "YAML_FILE", desc: "yaml file path"
        method_option :config_name, aliases: "-n", required: true, default: "default"
        method_option :cluster, aliases: "-c"
        method_option :cpu, type: :numeric
        method_option :memory, type: :numeric
        method_option :environments, aliases: "-e"
        method_option :task_role_arn
        method_option :timeout, type: :numeric
        method_option :launch_timeout, type: :numeric
        method_option :launch_retry, type: :numeric
        method_option :execution_retry, type: :numeric
        method_option :max_retry_interval, type: :numeric
        def run_cmd(*args)
          repo = Wrapbox::ConfigRepository.new.tap { |r| r.load_yaml(options[:config]) }
          config = repo.get(options[:config_name])
          config.runner = :ecs
          runner = config.build_runner
          environments = options[:environments].to_s.split(/,\s*/).map { |kv| kv.split("=") }.map do |k, v|
            {name: k, value: v}
          end
          run_options = {
            cluster: options[:cluster],
            task_role_arn: options[:task_role_arn],
            timeout: options[:timeout],
            launch_timeout: options[:launch_timeout],
            launch_retry: options[:launch_retry],
            execution_retry: options[:execution_retry],
            max_retry_interval: options[:max_retry_interval]
          }.reject { |_, v| v.nil? }
          if options[:cpu] || options[:memory]
            container_definition_overrides = {cpu: options[:cpu], memory: options[:memory]}.reject { |_, v| v.nil? }
          else
            container_definition_overrides = {}
          end
          runner.run_cmd(args, environments: environments, container_definition_overrides: container_definition_overrides, **run_options)
        end
      end
    end
  end
end
