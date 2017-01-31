require "open3"
require "multi_json"
require "docker"

module Wrapbox
  module Runner
    class Docker
      class ExecutionError < StandardError; end

      attr_reader \
        :name,
        :container_definition,
        :rm

      def initialize(options)
        @name = options[:name]
        @container_definition = options[:container_definition]
        @rm = options[:rm]
      end

      def run(class_name, method_name, args, container_definition_overrides: {}, environments: [])
        definition = container_definition
          .merge(container_definition_overrides)

        envs = base_environments(class_name, method_name, args)
        envs.concat(extract_environments(environments))

        exec_docker(definition: definition, cmd: ["bundle", "exec", "rake", "wrapbox:run"], environments: envs)
      end

      def run_cmd(*cmd,  container_definition_overrides: {}, environments: [])
        definition = container_definition
          .merge(container_definition_overrides)

        environments = extract_environments(environments)

        exec_docker(definition: definition, cmd: cmd, environments: environments)
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
          "Cmd" => cmd,
          "Env" => environments,
        }
        if definition[:cpu] || definition[:memory] || definition[:memory_reservation]
          options["HostConfig"] = {}
          options["HostConfig"]["Cpu"] == definition[:cpu]
          options["HostConfig"]["Memory"] == definition[:memory]
          options["HostConfig"]["MemoryReservation"] == definition[:memory_reservation]
        end
        container = ::Docker::Container.create(options)

        container.start!
        output_container_logs(container)
        resp = container.wait
        output_container_logs(container)

        unless resp["StatusCode"].zero?
          raise ExecutionError, "exit_code=#{resp["StatusCode"]}"
        end
      ensure
        container.remove(force: true) if container && @rm
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
    end
  end
end
