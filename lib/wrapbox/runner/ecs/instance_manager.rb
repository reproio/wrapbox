require "aws-sdk-ec2"
require "aws-sdk-ecs"

module Wrapbox
  module Runner
    class Ecs
      class InstanceManager
        def initialize(cluster, region, launch_template:, instance_type: nil, tag_specifications: nil, wait_until_instance_terminated: true)
          @cluster = cluster
          @region = region
          @launch_template = launch_template
          @instance_type = instance_type
          @tag_specifications = tag_specifications
          @wait_until_instance_terminated = wait_until_instance_terminated
          @queue = Queue.new
          @instance_ids = []
        end

        def pop_ec2_instance_id
          Wrapbox.logger.debug("Wait until a new container instance are registered in \"#{@cluster}\" cluster")
          @queue.pop
        end

        def start_preparing_instances(count)
          preparing_instance_ids = ec2_client.run_instances(
            launch_template: @launch_template,
            instance_type: @instance_type,
            tag_specifications: @tag_specifications,
            min_count: count,
            max_count: count
          ).instances.map(&:instance_id)
          @instance_ids.concat(preparing_instance_ids)
          ec2_client.wait_until(:instance_running, instance_ids: preparing_instance_ids)

          waiter = Aws::Waiters::Waiter.new(
            max_attempts: 40,
            delay: 15,
            poller: Aws::Waiters::Poller.new(
              operation_name: :list_container_instances,
              acceptors: [
                {
                  "expected" => true,
                  "matcher" => "path",
                  "state" => "success",
                  "argument" => "length(container_instance_arns) > `0`"
                }
              ]
            )
          )

          while preparing_instance_ids.size > 0
            waiter.wait(client: ecs_client, params: { cluster: @cluster, filter: "ec2InstanceId in [#{preparing_instance_ids.join(",")}]" }).each do |resp|
              ecs_client.describe_container_instances(cluster: @cluster, container_instances: resp.container_instance_arns).container_instances.each do |c|
                preparing_instance_ids.delete(c.ec2_instance_id)
                @queue << c.ec2_instance_id
              end
            end
          end
        end

        def terminate_instance(instance_id)
          ec2_client.terminate_instances(instance_ids: [instance_id])
          if @wait_until_instance_terminated
            ec2_client.wait_until(:instance_terminated, instance_ids: [instance_id])
          end
          @instance_ids.delete(instance_id)
        end

        def terminate_all_instances
          # Duplicate @instance_ids because other threads can change it
          remaining_instance_ids = @instance_ids.dup
          return if remaining_instance_ids.empty?
          ec2_client.terminate_instances(instance_ids: remaining_instance_ids)
          if @wait_until_instance_terminated
            ec2_client.wait_until(:instance_terminated, instance_ids: remaining_instance_ids)
          end
          @instance_ids.clear
        end

        private

        def ecs_client
          @ecs_client ||= Aws::ECS::Client.new({ region: @region }.reject { |_, v| v.nil? })
        end

        def ec2_client
          @ec2_client ||= Aws::EC2::Client.new({ region: @region }.reject { |_, v| v.nil? })
        end
      end
    end
  end
end
