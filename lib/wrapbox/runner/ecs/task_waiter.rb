require "timeout"

require "aws-sdk-ecs"

module Wrapbox
  module Runner
    class Ecs
      class TaskWaiter
        MAX_DESCRIBABLE_TASK_COUNT = 100

        class WaitFailure < StandardError; end
        class TaskStopped < WaitFailure; end
        class TaskMissing < WaitFailure; end
        class UnknownFailure < WaitFailure; end
        class WaitTimeout < WaitFailure; end

        def initialize(cluster:, region:, delay:)
          @cluster = cluster
          @region = region
          @task_arn_to_described_result = {}
          @mutex = Mutex.new
          @cv = ConditionVariable.new
          Thread.new { update_described_results(delay) }
        end

        # @return Aws::ECS::Types::Task
        def wait_task_running(task_arn, timeout: 0)
          Timeout.timeout(timeout) do
            loop do
              result = describe_task(task_arn)
              if result[:failure]
                case result[:failure].reason
                when "MISSING"
                  raise TaskMissing
                else
                  raise UnknownFailure
                end
              end
              raise TaskStopped if result[:task].last_status == "STOPPED"

              return result[:task] if result[:task].last_status == "RUNNING"
            end
          end
        rescue Timeout::Error
          raise WaitTimeout
        end

        # @return Aws::ECS::Types::Task
        def wait_task_stopped(task_arn, timeout: 0)
          Timeout.timeout(timeout) do
            result = nil
            loop do
              result = describe_task(task_arn)
              if result[:failure]
                case result[:failure].reason
                when "MISSING"
                  raise TaskMissing
                else
                  raise UnknownFailure
                end
              end

              return result[:task] if result[:task].last_status == "STOPPED"
            end
          end
        rescue Timeout::Error
          raise WaitTimeout
        end

        private

        def describe_task(task_arn)
          @mutex.synchronize do
            @task_arn_to_described_result[task_arn] = nil
            @cv.wait(@mutex)
            @task_arn_to_described_result[task_arn]
          end
        ensure
          @mutex.synchronize do
            @task_arn_to_described_result.delete(task_arn)
          end
        end

        def update_described_results(interval)
          loop do
            @mutex.synchronize do
              unless @task_arn_to_described_result.empty?
                begin
                  @task_arn_to_described_result.keys.each_slice(MAX_DESCRIBABLE_TASK_COUNT) do |task_arns|
                    resp = ecs_client.describe_tasks(cluster: @cluster, tasks: task_arns)
                    resp.tasks.each do |task|
                      @task_arn_to_described_result[task.task_arn] = { task: task }
                    end
                    resp.failures.each do |failure|
                      # failure.arn is like "arn:aws:ecs:<region>:<account-id>:task/<task-id>"
                      # even if task_arn is like "arn:aws:ecs:<region>:<account-id>:task/<cluster>/<task-id>"
                      prefix, suffix = failure.arn.split("/")
                      task_arn = task_arns.find { |a| a.start_with?(prefix) && a.end_with?(suffix) }
                      @task_arn_to_described_result[task_arn || failure.arn] = { failure: failure }
                    end
                  end

                  @cv.broadcast
                rescue Aws::ECS::Errors::ThrottlingException
                  Wrapbox.logger.warn("Failed to describe tasks due to Aws::ECS::Errors::ThrottlingException")
                end
              end
            end

            sleep interval
          end
        end

        def ecs_client
          @ecs_client ||= Aws::ECS::Client.new({ region: @region }.reject { |_, v| v.nil? })
        end
      end
    end
  end
end
