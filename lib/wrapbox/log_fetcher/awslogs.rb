module Wrapbox
  module LogFetcher
    class Awslogs
      STOP_WAIT_TIMELIMIT = 10

      def initialize(log_group:, log_stream_prefix:, filter_pattern: nil, region: nil, access_key_id: nil, secret_access_key: nil, timestamp_format: "%Y-%m-%d %H:%M:%S.%3N", delay: 2, **options)
        begin
          require 'aws-sdk-cloudwatchlogs'
        rescue LoadError
          $stderr.puts "Require aws-sdk-cloudwatchlogs gem"
          exit 1
        end

        @log_group = log_group
        @log_stream_prefix = log_stream_prefix
        @filter_pattern = filter_pattern
        @region = region
        @access_key_id = access_key_id
        @secret_access_key = secret_access_key
        @timestamp_format = timestamp_format
        @delay = delay
        @options = options.reject { |_, v| v.nil? }
        @displayed_log_stream_names = {}
        @displayed_log_stream_number = 0
        @displayed_event_ids = {}
      end

      def run(task:)
        @loop_thread = Thread.start do
          # It smees that task.contaienrs is empty
          # if capacity_provider_strategy is specified and there are no remaining capacity
          while task.containers.empty?
            Wrapbox.logger.warn("The task has no containers, so fetch it again")
            sleep 10
            task = ecs_client.describe_tasks(cluster: task.cluster_arn, tasks: [task.task_arn]).tasks.first
          end

          main_loop(task)
        end
      end

      def stop
        @stop = true
        @loop_thread&.join(STOP_WAIT_TIMELIMIT)
      end

      def main_loop(task)
        task_id = task.task_arn.split("/").last
        log_stream_names = task.containers.map do |container|
          [@log_stream_prefix, container.name, task_id].join("/")
        end
        filter_log_opts = {
          log_group_name: @log_group,
          log_stream_names: log_stream_names,
          filter_pattern: @filter_pattern,
        }.compact
        @max_timestamp = ((Time.now.to_f - 120) * 1000).round

        until @stop do
          filter_log_opts[:start_time] = @max_timestamp + 1
          begin
            client.filter_log_events(filter_log_opts).each do |r|
              r.events.each do |ev|
                next if @displayed_event_ids.member?(ev.event_id)
                display_message(ev)
                @displayed_event_ids[ev.event_id] = ev.timestamp
                @max_timestamp = ev.timestamp if @max_timestamp < ev.timestamp
              end
            end

            @displayed_event_ids.each do |event_id, ts|
              if ts < (Time.now.to_f - 600) * 1000
                @displayed_event_ids.delete(event_id)
              end
            end
          rescue Aws::CloudWatchLogs::Errors::ResourceNotFoundException
            # Ignore the error because it is an error like "The specified log stream does not exist.",
            # which occurs when the log stream hasn't been created yet, that is, the task hasn't started yet.
          rescue Aws::CloudWatchLogs::Errors::ThrottlingException
            Wrapbox.logger.warn("Failed to fetch logs due to Aws::CloudWatchLogs::Errors::ThrottlingException")
          end

          sleep @delay
        end
      end

      COLOR_ESCAPE_SEQUENCES = [33, 31, 32, 34, 35, 36]
      def display_message(ev, output: $stdout)
        num = @displayed_log_stream_names.fetch(ev.log_stream_name) do |key|
          current = @displayed_log_stream_number
          @displayed_log_stream_names[key] = current
          @displayed_log_stream_number += 1
          current
        end

        sequence_number = COLOR_ESCAPE_SEQUENCES[num % COLOR_ESCAPE_SEQUENCES.length]

        time = Time.at(ev.timestamp / 1000.0)
        output.puts("\e[#{sequence_number}m#{time.strftime(@timestamp_format)} #{ev.log_stream_name}\e[0m #{ev.message}")
      end

      private

      def client
        return @client if @client

        options = {
          region: @region,
          access_key_id: @access_key_id,
          secret_access_key: @secret_access_key,
        }.compact
        @client = Aws::CloudWatchLogs::Client.new(**options)
      end
    end
  end
end
