require "open3"
require "multi_json"
require "docker"
require "thor"
require "shellwords"

require "wrapbox"

module Wrapbox
  module Runner
    class Docker
      class ExecutionError < StandardError; end

      attr_reader \
        :name,
        :container_definition,
        :keep_container

      def initialize(options)
        @name = options[:name]
        @container_definitions = options[:container_definition] ? [options[:container_definition]] : options[:container_definitions]
        @logger = Wrapbox.logger

        if @container_definitions.size >= 2
          raise "Docker runner does not support multi container currently"
        end

        @container_definition = @container_definitions[0]

        @keep_container = options[:keep_container]
      end

      def run(class_name, method_name, args, container_definition_overrides: {}, environments: [])
        definition = container_definition
          .merge(container_definition_overrides)

        envs = base_environments(class_name, method_name, args)
        envs.concat(extract_environments(environments))

        exec_docker(definition: definition, cmd: ["bundle", "exec", "rake", "wrapbox:run"], environments: envs)
      end

      def run_cmd(cmds,  container_definition_overrides: {}, environments: [], ignore_signal: false)
        ths = []
        definition = container_definition
          .merge(container_definition_overrides)

        environments = extract_environments(environments)

        cmds << nil if cmds.empty?
        cmds.each_with_index do |cmd, idx|
          ths << Thread.new(cmd, idx) do |c, i|
            envs = environments + ["WRAPBOX_CMD_INDEX=#{idx}"]
            exec_docker(
              definition: definition,
              cmd: c&.shellsplit,
              environments: envs
            )
          end
        end
        ths.each { |th| th&.join }

        true
      rescue SignalException => e
        sig = "SIG#{Signal.signame(e.signo)}"
        if ignore_signal
          @logger.info("Receive #{sig} signal. But Docker container continue running")
        else
          @logger.info("Receive #{sig} signal. Stop All tasks")
          ths.each do |th|
            th.report_on_exception = false
            th.raise(e)
          end
          thread_timeout = 15
          ths.each { |th| th.join(thread_timeout) }
        end
        nil
      end

      private

      def base_environments(class_name, method_name, args)
        ["#{CLASS_NAME_ENV}=#{class_name}", "#{METHOD_NAME_ENV}=#{method_name}", "#{METHOD_ARGS_ENV}=#{MultiJson.dump(args)}"]
      end

      def extract_environments(environments)
        environments.map do |e|
          "#{e[:name]}=#{e[:value]}"
        end
      end

      def exec_docker(definition:, cmd:, environments: [])
        ::Docker::Image.create("fromImage" => definition[:image])
        options = {
          "Image" => definition[:image],
          "Env" => environments,
        }.tap { |o| o["Cmd"] = cmd if cmd }
        options["HostConfig"] = {}
        options["HostConfig"]["Cpu"] = definition[:cpu] if definition[:cpu]
        options["HostConfig"]["Memory"] = definition[:memory] * 1024 * 1024 if definition[:memory]
        options["HostConfig"]["MemoryReservation"] = definition[:memory_reservation] * 1024 * 1024 if definition[:memory_reservation]
        options["HostConfig"]["Links"] = definition[:links]
        options["Entrypoint"] = definition[:entry_point] if definition[:entry_point]
        options["WorkingDir"] = definition[:working_directory] if definition[:working_directory]

        container = ::Docker::Container.create(options)

        container.start
        output_container_logs(container)
        resp = container.wait
        output_container_logs(container)

        unless resp["StatusCode"].zero?
          raise ExecutionError, "exit_code=#{resp["StatusCode"]}"
        end
      rescue SignalException => e
        sig = Signal.signame(e.signo)
        container&.kill(signal: sig)
      ensure
        container.remove(force: true) if container && !keep_container
      end

      def output_container_logs(container)
        container.streaming_logs(stdout: true, stderr: true) do |stream, chunk|
          if stream == "stdout"
            $stdout.puts(chunk)
          else
            $stderr.puts(chunk)
          end
        end
      end

      class Cli < Thor
        namespace :docker

        desc "run_cmd [shell command]", "Run shell on docker"
        method_option :config, aliases: "-f", required: true, banner: "YAML_FILE", desc: "yaml file path"
        method_option :config_name, aliases: "-n", required: true, default: "default"
        method_option :cpu, type: :numeric
        method_option :memory, type: :numeric
        method_option :working_directory, aliases: "-w", type: :string
        method_option :environments, aliases: "-e"
        method_option :ignore_signal, type: :boolean, default: false, desc: "Even if receive a signal (like TERM, INT, QUIT), Docker container continue running"
        method_option :verbose, aliases: "-v", type: :boolean, default: false, desc: "Verbose mode"
        def run_cmd(*args)
          Wrapbox.logger.level = :debug if options[:verbose]
          Wrapbox.load_config(options[:config])
          config = Wrapbox.configs[options[:config_name]]
          environments = options[:environments].to_s.scan(/\w+?=(?:'.+?'|".+?"|\w+)/).map { |kv| kv.split("=") }.map do |k, v|
            {name: k, value: v}
          end
          if options[:cpu] || options[:memory] || options[:working_directory]
            container_definition_overrides = {cpu: options[:cpu], memory: options[:memory], working_directory: options[:working_directory]}.reject { |_, v| v.nil? }
          else
            container_definition_overrides = {}
          end
          unless config.run_cmd(args, runner: "docker", environments: environments, container_definition_overrides: container_definition_overrides, ignore_signal: options[:ignore_signal])
            exit 1
          end
        end
      end
    end
  end
end
