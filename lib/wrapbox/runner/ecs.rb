require "aws-sdk-ecs"
require "aws-sdk-cloudwatch"
require "multi_json"
require "thor"
require "yaml"
require "active_support/core_ext/hash"
require "pp"
require "shellwords"
require "thwait"

require "wrapbox"
require "wrapbox/config_repository"
require "wrapbox/log_fetcher"
require "wrapbox/runner/ecs/instance_manager"
require "wrapbox/runner/ecs/task_waiter"
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
      TERM_TIMEOUT = 120
      HOST_TERMINATED_REASON_REGEXP = /Host EC2.*terminated/

      attr_reader \
        :name,
        :revision,
        :region,
        :container_definitions,
        :volumes,
        :placement_constraints,
        :placement_strategy,
        :requires_compatibilities,
        :task_definition_name,
        :main_container_name,
        :network_mode,
        :network_configuration,
        :cpu,
        :memory,
        :enable_ecs_managed_tags,
        :tags,
        :propagate_tags

      def self.split_overridable_options_and_parameters(options)
        opts = options.dup
        overridable_options = {}
        %i[cluster launch_type task_role_arn execution_role_arn].each do |key|
          value = opts.delete(key)
          overridable_options[key] = value if value
        end

        [overridable_options, opts]
      end

      def initialize(options)
        @name = options[:name]
        @task_definition_name = options[:task_definition_name]
        @revision = options[:revision]
        @cluster = options[:cluster]
        @region = options[:region]
        @volumes = options[:volumes]
        @placement_constraints = options[:placement_constraints] || []
        @placement_strategy = options[:placement_strategy]
        @capacity_provider_strategy = options[:capacity_provider_strategy] || []
        @launch_type = options[:launch_type]
        @requires_compatibilities = options[:requires_compatibilities]
        @network_mode = options[:network_mode]
        @network_configuration = options[:network_configuration]
        @cpu = options[:cpu]
        @memory = options[:memory]
        @enable_ecs_managed_tags = options[:enable_ecs_managed_tags]
        @tags = options[:tags]
        @propagate_tags = options[:propagate_tags]
        if options[:launch_instances]
          @instance_manager = Wrapbox::Runner::Ecs::InstanceManager.new(@cluster, @region, options[:launch_instances])
        end
        @task_waiter = Wrapbox::Runner::Ecs::TaskWaiter.new(cluster: @cluster, region: @region, delay: WAIT_DELAY)

        @container_definitions = options[:container_definition] ? [options[:container_definition]] : options[:container_definitions] || []
        @container_definitions.concat(options[:additional_container_definitions]) if options[:additional_container_definitions] # deprecated

        if !@container_definitions.empty? && options[:task_definition]
          raise "Please set only one of `container_definition` and `task_definition`"
        end

        if options[:additional_container_definitions] && !options[:additional_container_definitions].empty?
          warn "`additional_container_definitions` is deprecated parameter, Use `container_definitions` instead of it"
        end

        @task_definition_info = options[:task_definition]

        if !@container_definitions.empty?
          @task_definition_name ||= "wrapbox_#{@name}"
          @main_container_name = @container_definitions[0][:name] || @task_definition_name
        elsif @task_definition_info
          @task_definition_name = @task_definition_info[:task_definition_name]
          @main_container_name = @task_definition_info[:main_container_name]
          unless @main_container_name
            raise "Please set `task_definition[:main_container_name]`"
          end
        end

        @container_definitions.each do |d|
          d[:docker_labels]&.stringify_keys!
          d.dig(:log_configuration, :options)&.stringify_keys!
        end

        @task_role_arn = options[:task_role_arn]
        @execution_role_arn = options[:execution_role_arn]
        @logger = Wrapbox.logger
        if options[:log_fetcher]
          type = options[:log_fetcher][:type]
          @log_fetcher = LogFetcher.new(type, options[:log_fetcher])
        end
      end

      class Parameter
        attr_reader \
          :environments,
          :timeout,
          :launch_timeout,
          :launch_retry,
          :retry_interval,
          :retry_interval_multiplier,
          :max_retry_interval,
          :execution_retry

        def initialize(environments: [], timeout: 3600 * 24, launch_timeout: 60 * 10, launch_retry: 10, retry_interval: 1, retry_interval_multiplier: 2, max_retry_interval: 120, execution_retry: 0)
          b = binding
          method(:initialize).parameters.each do |param|
            instance_variable_set("@#{param[1]}", b.local_variable_get(param[1]))
          end
        end
      end

      def run(class_name, method_name, args, container_definition_overrides: {}, **parameters)
        task_definition = prepare_task_definition(container_definition_overrides)
        parameter = Parameter.new(**parameters)

        envs = parameters[:environments] || []
        envs += [
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

        if @instance_manager
          Thread.new { @instance_manager.start_preparing_instances(1) }
        end

        run_task(task_definition.task_definition_arn, ["bundle", "exec", "rake", "wrapbox:run"], envs, parameter)
      ensure
        @instance_manager&.terminate_all_instances
      end

      def run_cmd(cmds, container_definition_overrides: {}, ignore_signal: false, **parameters)
        ths = []

        task_definition = prepare_task_definition(container_definition_overrides)
        parameter = Parameter.new(**parameters)

        cmds << nil if cmds.empty?

        if @instance_manager
          Thread.new { @instance_manager.start_preparing_instances(cmds.size) }
        end

        cmds.each_with_index do |cmd, idx|
          ths << Thread.new(cmd, idx) do |c, i|
            Thread.current[:cmd_index] = i
            envs = (parameters[:environments] || []) + [{name: "WRAPBOX_CMD_INDEX", value: i.to_s}]
            run_task(task_definition.task_definition_arn, c&.shellsplit, envs, parameter)
          end
        end
        ThreadsWait.all_waits(ths)
        # Raise an error if some threads have an error
        ths.each(&:join)

        true
      rescue SignalException => e
        sig = "SIG#{Signal.signame(e.signo)}"
        if ignore_signal
          @logger.info("Receive #{sig} signal. But ECS Tasks continue running")
        else
          @logger.info("Receive #{sig} signal. Stop All tasks")
          ths.each do |th|
            th.report_on_exception = false
            th.raise(e)
          end
          wait_until = Time.now + TERM_TIMEOUT + 15 # thread_timeout_buffer
          ths.each do |th|
            wait = wait_until - Time.now
            th.join(wait) if wait.positive?
          end
        end
        nil
      ensure
        @instance_manager&.terminate_all_instances
      end

      private

      def use_existing_task_definition?
        !!@task_definition_info
      end

      def run_task(task_definition_arn, command, environments, parameter)
        execution_try_count = 0

        ec2_instance_id = @instance_manager&.pop_ec2_instance_id
        begin
          task = create_task(task_definition_arn, command, environments, parameter, ec2_instance_id)
          return unless task # only Task creation aborted by SignalException

          @logger.info("#{log_prefix}Launch Task: #{task.task_arn}")

          wait_task_stopped(task.task_arn, parameter.timeout)

          @logger.info("#{log_prefix}Stop Task: #{task.task_arn}")

          # Avoid container exit code fetch miss
          sleep WAIT_DELAY

          task_status = fetch_task_status(task.task_arn)

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
            @logger.warn("#{log_prefix}Retry Execution after #{EXECUTION_RETRY_INTERVAL} sec (#{execution_try_count}/#{parameter.execution_retry})")
            sleep EXECUTION_RETRY_INTERVAL
            retry
          end
        rescue SignalException
          client.stop_task(
            cluster: @cluster,
            task: task.task_arn,
            reason: "signal interrupted"
          )
          wait_task_stopped(task.task_arn, TERM_TIMEOUT)
          @logger.debug("#{log_prefix}Stop Task: #{task.task_arn}")
        ensure
          if @log_fetcher
            begin
              @log_fetcher.stop
            rescue => e
              @logger.warn(e)
            end
          end
          @instance_manager.terminate_instance(ec2_instance_id) if ec2_instance_id
        end
      end

      def create_task(task_definition_arn, command, environments, parameter, ec2_instance_id)
        args = Array(args)

        launch_try_count = 0
        current_retry_interval = parameter.retry_interval

        begin
          run_task_options = build_run_task_options(task_definition_arn, command, environments, ec2_instance_id)
          @logger.debug("#{log_prefix}Task Options: #{run_task_options}")

          begin
            resp = client.run_task(run_task_options)
            puts resp.to_json
          rescue Aws::ECS::Errors::ThrottlingException
            @logger.warn("#{log_prefix}Failure: Rate exceeded.")
            raise LaunchFailure
          end
          task = resp.tasks[0]

          resp.failures.each do |failure|
            @logger.warn("#{log_prefix}Failure: Arn=#{failure.arn}, Reason=#{failure.reason}")
          end
          raise LackResource unless task # this case is almost lack of container resource.

          @logger.debug("#{log_prefix}Create Task: #{task.task_arn}")

          @log_fetcher.run(task: task) if @log_fetcher

          # Wait ECS Task Status becomes stable
          sleep WAIT_DELAY

          begin
            wait_task_running(task.task_arn, parameter.launch_timeout)
            task
          rescue Wrapbox::Runner::Ecs::TaskWaiter::WaitTimeout
            client.stop_task(
              cluster: @cluster,
              task: task.task_arn,
              reason: "launch timeout"
            )
            raise
          rescue Wrapbox::Runner::Ecs::TaskWaiter::WaitFailure
            task_status = fetch_task_status(task.task_arn)

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
          @logger.warn("#{log_prefix}Failed to create task, because of lack resource")
          put_waiting_task_count_metric

          if launch_try_count >= parameter.launch_retry
            raise
          else
            launch_try_count += 1
            retry_interval = current_retry_interval/2 + rand(current_retry_interval/2)
            @logger.warn("#{log_prefix}Retry Create Task after #{retry_interval} sec (#{launch_try_count}/#{parameter.launch_retry})")
            sleep retry_interval
            current_retry_interval = [current_retry_interval * parameter.retry_interval_multiplier, parameter.max_retry_interval].min
            retry
          end
        rescue LaunchFailure
          if launch_try_count >= parameter.launch_retry
            task_status = fetch_task_status(task.task_arn)
            raise LaunchFailure, build_error_message(task_definition_name, task.task_arn, task_status)
          else
            launch_try_count += 1
            retry_interval = current_retry_interval/2 + rand(current_retry_interval/2)
            @logger.warn("#{log_prefix}Retry Create Task after #{retry_interval} sec (#{launch_try_count}/#{parameter.launch_retry})")
            sleep retry_interval
            current_retry_interval = [current_retry_interval * parameter.retry_interval_multiplier, parameter.max_retry_interval].min
            retry
          end
        rescue SignalException
          if task
            client.stop_task(
              cluster: @cluster,
              task: task.task_arn,
              reason: "signal interrupted"
            )
            wait_task_stopped(task.task_arn, TERM_TIMEOUT)
            @logger.debug("#{log_prefix}Stop Task: #{task.task_arn}")
            nil
          end
        end
      end

      def wait_task_running(task_arn, launch_timeout)
        @task_waiter.wait_task_running(task_arn, timeout: launch_timeout)
      end

      def wait_task_stopped(task_arn, execution_timeout)
        @task_waiter.wait_task_stopped(task_arn, timeout: execution_timeout)
      rescue Wrapbox::Runner::Ecs::TaskWaiter::WaitTimeout
        client.stop_task({
          cluster: @cluster,
          task: task_arn,
          reason: "process timeout",
        })
        raise ExecutionTimeout, "Task #{task_definition_name} is timeout. task=#{task_arn}, timeout=#{execution_timeout}"
      end

      def fetch_task_status(task_arn)
        task = client.describe_tasks(cluster: @cluster, tasks: [task_arn]).tasks[0]
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
        main_container_definition = container_definitions[0]
        main_container_definition = main_container_definition
          .merge(container_definition_overrides)
          .merge(name: main_container_name)

        overrided_container_definitions = [main_container_definition, *(container_definitions.drop(1))]

        if revision
          begin
            return client.describe_task_definition(task_definition: "#{task_definition_name}:#{revision}").task_definition
          rescue
          end
        end

        @logger.debug("#{log_prefix}Container Definitions: #{overrided_container_definitions}")
        register_retry_count = 0
        begin
          client.register_task_definition({
            family: task_definition_name,
            cpu: cpu,
            memory: memory,
            network_mode: network_mode,
            container_definitions: overrided_container_definitions,
            volumes: volumes,
            requires_compatibilities: requires_compatibilities,
            task_role_arn: @task_role_arn,
            execution_role_arn: @execution_role_arn,
            tags: tags,
          }).task_definition
        rescue Aws::ECS::Errors::ClientException
          raise if register_retry_count > 2
          register_retry_count += 1
          sleep 2
          retry
        end
      end

      def cmd_index
        Thread.current[:cmd_index]
      end

      def log_prefix
        cmd_index ? "##{cmd_index} " : ""
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

      def put_waiting_task_count_metric
        cloud_watch_client.put_metric_data(
          namespace: "wrapbox",
          metric_data: [
            metric_name: "WaitingTaskCount",
            dimensions: [
              {
                name: "ClusterName",
                value: @cluster,
              },
            ],
            timestamp: Time.now,
            value: 1.0,
            unit: "Count",
          ]
        )
      end

      def build_run_task_options(task_definition_arn, command, environments, ec2_instance_id)
        overrides = {
          container_overrides: [
            {
              name: main_container_name,
              environment: environments,
            }.tap { |o| o[:command] = command if command },
            *container_definitions.drop(1).map do |c|
              {
                name: c[:name],
                environment: environments,
              }
            end
          ],
        }
        overrides[:task_role_arn] = @task_role_arn if @task_role_arn

        additional_placement_constraints = []
        if ec2_instance_id
          additional_placement_constraints << { type: "memberOf", expression: "ec2InstanceId == #{ec2_instance_id}" }
        end
        options = {
          cluster: @cluster,
          task_definition: task_definition_arn,
          overrides: overrides,
          placement_strategy: placement_strategy,
          placement_constraints: placement_constraints + additional_placement_constraints,
          network_configuration: network_configuration,
          started_by: "wrapbox-#{Wrapbox::VERSION}",
          enable_ecs_managed_tags: enable_ecs_managed_tags,
          propagate_tags: propagate_tags,
        }
        if @capacity_provider_strategy.empty?
          options[:launch_type] = @launch_type if @launch_type
        else
          options[:capacity_provider_strategy] = @capacity_provider_strategy
        end
        options
      end

      def build_error_message(task_definition_name, task_arn, task_status)
        error_message = "Task #{task_definition_name} is failed. task=#{task_arn}, "
        error_message << "cmd_index=#{cmd_index}, " if cmd_index
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
        method_option :working_directory, aliases: "-w", type: :string
        method_option :environments, aliases: "-e"
        method_option :task_role_arn
        method_option :timeout, type: :numeric
        method_option :launch_type, type: :string, enum: ["EC2", "FARGATE"]
        method_option :launch_timeout, type: :numeric
        method_option :launch_retry, type: :numeric
        method_option :execution_retry, type: :numeric
        method_option :max_retry_interval, type: :numeric
        method_option :ignore_signal, type: :boolean, default: false, desc: "Even if receive a signal (like TERM, INT, QUIT), ECS Tasks continue running"
        method_option :verbose, aliases: "-v", type: :boolean, default: false, desc: "Verbose mode"
        def run_cmd(*args)
          Wrapbox.logger.level = :debug if options[:verbose]
          Wrapbox.load_config(options[:config])
          config = Wrapbox.configs[options[:config_name]]
          environments = options[:environments].to_s.split(/,\s*/).map { |kv| kv.split("=") }.map do |k, v|
            {name: k, value: v}
          end
          run_options = {
            cluster: options[:cluster],
            task_role_arn: options[:task_role_arn],
            timeout: options[:timeout],
            launch_type: options[:launch_type],
            launch_timeout: options[:launch_timeout],
            launch_retry: options[:launch_retry],
            execution_retry: options[:execution_retry],
            max_retry_interval: options[:max_retry_interval],
            ignore_signal: options[:ignore_signal],
          }.reject { |_, v| v.nil? }
          if options[:cpu] || options[:memory] || options[:working_directory]
            container_definition_overrides = {cpu: options[:cpu], memory: options[:memory], working_directory: options[:working_directory]}.reject { |_, v| v.nil? }
          else
            container_definition_overrides = {}
          end
          unless config.run_cmd(args, runner: "ecs", environments: environments, container_definition_overrides: container_definition_overrides, **run_options)
            exit 1
          end
        end
      end
    end
  end
end
