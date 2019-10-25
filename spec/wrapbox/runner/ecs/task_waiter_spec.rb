require "spec_helper"

require "wrapbox/runner/ecs/task_waiter"

describe Wrapbox::Runner::Ecs::TaskWaiter do
  let(:waiter) { described_class.new(cluster: "default", region: "ap-northeast-1", delay: 0.01) }
  let(:ecs_client) { Aws::ECS::Client.new(stub_responses: true) }

  before do
    allow(waiter).to receive(:ecs_client) { ecs_client }
  end

  def start_thread
    Thread.new do
      Thread.current.report_on_exception = false
      yield
    end
  end

  describe "#wait_task_running" do
    let(:running_task_arn) { "arn:aws:ecs:ap-northeast-1:1234:task/default/3f83f7c37e41d1862874a84a6eefd7c7" }
    let(:stopped_task_arn) { "arn:aws:ecs:ap-northeast-1:1234:task/default/ac65e038e840c7e4206c88018924f3a5" }
    let(:missing_task_arn) { "arn:aws:ecs:ap-northeast-1:1234:task/default/c5382e88b8c2bbd6888f36bfd9bd32e8" }

    before do
      ecs_client.stub_responses(:describe_tasks, {
        tasks: [
          { task_arn: running_task_arn, last_status: "PENDING" },
          { task_arn: stopped_task_arn, last_status: "PENDING" },
        ],
        failures: [
          { reason: "MISSING", arn: missing_task_arn.sub("/default", '') },
        ]
      })
    end

    it "waits until specifined tasks run" do
      running_task_th = start_thread { waiter.wait_task_running(running_task_arn) }
      stopped_task_th = start_thread { waiter.wait_task_running(stopped_task_arn) }
      missing_task_th = start_thread { waiter.wait_task_running(missing_task_arn) }

      ecs_client.stub_responses(:describe_tasks, {
        tasks: [
          { task_arn: running_task_arn, last_status: "RUNNING" },
          { task_arn: stopped_task_arn, last_status: "STOPPED" },
        ],
        failures: [
          { reason: "MISSING", arn: missing_task_arn.sub("/default", '') },
        ]
      })

      expect(running_task_th.value.task_arn).to eq running_task_arn
      expect { stopped_task_th.value }.to raise_error(described_class::TaskStopped)
      expect { missing_task_th.value }.to raise_error(described_class::TaskMissing)
      expect(waiter.instance_variable_get(:@task_arn_to_described_result)).to be_empty
    end

    it { expect { waiter.wait_task_running(running_task_arn, timeout: 0.01) }.to raise_error(described_class::WaitTimeout) }
  end

  describe "#wait_task_stopped" do
    let(:stopped_task_arn) { "arn:aws:ecs:ap-northeast-1:1234:task/default/ac65e038e840c7e4206c88018924f3a5" }
    let(:missing_task_arn) { "arn:aws:ecs:ap-northeast-1:1234:task/default/c5382e88b8c2bbd6888f36bfd9bd32e8" }

    before do
      ecs_client.stub_responses(:describe_tasks, {
        tasks: [
          { task_arn: stopped_task_arn, last_status: "PENDING" },
        ],
        failures: [
          { reason: "MISSING", arn: missing_task_arn.sub("/default", '') },
        ]
      })
    end

    it "waits until specifined tasks stop" do
      stopped_task_th = start_thread { waiter.wait_task_stopped(stopped_task_arn) }
      missing_task_th = start_thread { waiter.wait_task_stopped(missing_task_arn) }

      ecs_client.stub_responses(:describe_tasks, {
        tasks: [
          { task_arn: stopped_task_arn, last_status: "STOPPED" },
        ],
        failures: [
          { reason: "MISSING", arn: missing_task_arn.sub("/default", '') },
        ]
      })

      expect(stopped_task_th.value.task_arn).to eq stopped_task_arn
      expect { missing_task_th.value }.to raise_error(described_class::TaskMissing)
      expect(waiter.instance_variable_get(:@task_arn_to_described_result)).to be_empty
    end

    it { expect { waiter.wait_task_stopped(stopped_task_arn, timeout: 0.01) }.to raise_error(described_class::WaitTimeout) }
  end
end
