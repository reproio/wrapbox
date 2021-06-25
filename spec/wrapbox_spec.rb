require "spec_helper"

describe Wrapbox do
  it "can load yaml" do
    config = Wrapbox.configs[:default]
    expect(config.cluster).to eq(ENV["ECS_CLUSTER"])
    expect(config.region).to eq("ap-northeast-1")
    expect(config.enable_execute_command).to be_falsey
    expect(config.container_definition[:cpu]).to be_a(Integer)
  end

  describe 'enable_execute_command option is true' do
    specify "config value is true" do
      config = Wrapbox.configs[:ecs_enable_execute_command]
      expect(config.enable_execute_command).to be_truthy
    end
  end

  describe 'enable_execute_command option is false' do
    specify "config value is false" do
      config = Wrapbox.configs[:ecs_disable_execute_command]
      expect(config.enable_execute_command).to be_falsey
    end
  end

  describe ".run" do
    specify "executable on ECS", aws: true do
      Wrapbox.run("TestJob", :perform, ["arg1", ["arg2", "arg3"]], environments: [{name: "RAILS_ENV", value: "development"}])
    end

    specify "executable on Docker" do
      Wrapbox.run("TestJob", :perform, ["arg1", ["arg2", "arg3"]], config_name: :docker, environments: [{name: "RAILS_ENV", value: "development"}])
    end

    specify "executable on ECS with launch template", aws: true do
      Wrapbox.run("TestJob", :perform, ["arg1", ["arg2", "arg3"]], config_name: :ecs_with_launch_template, environments: [{name: "RAILS_ENV", value: "development"}])
    end
  end

  describe ".run_cmd" do
    specify "executable on ECS", aws: true do
      Wrapbox.run_cmd(["ls ."], environments: [{name: "RAILS_ENV", value: "development"}])
    end

    specify "executable on ECS overriding `cluster`", aws: true do
      default_clusters = [nil, "", "default"]
      if ENV["OVERRIDDEN_ECS_CLUSTER"].nil?
        raise "Specify OVERRIDDEN_ECS_CLUSTER"
      end
      if ENV["ECS_CLUSTER"] == ENV["OVERRIDDEN_ECS_CLUSTER"] || (default_clusters.include?(ENV["ECS_CLUSTER"]) && default_clusters.include?(ENV["OVERRIDDEN_ECS_CLUSTER"]))
        raise "Specify different values for ECS_CLUSTER and OVERRIDDEN_ECS_CLUSTER"
      end
      Wrapbox.run_cmd(["ls ."], environments: [{name: "RAILS_ENV", value: "development"}], cluster: ENV["OVERRIDDEN_ECS_CLUSTER"])
    end

    specify "executable on ECS overriding `runner`", aws: true do
      expect(Wrapbox::Runner::Ecs).to receive(:new).and_call_original
      Wrapbox.run_cmd(["ls ."], config_name: :ecs_without_runner, runner: "ecs", environments: [{name: "RAILS_ENV", value: "development"}])
    end

    specify "executable on ECS with launch template", aws: true do
      Wrapbox.run_cmd(["ls ."], config_name: :ecs_with_launch_template, environments: [{name: "RAILS_ENV", value: "development"}])
    end

    specify "executable on ECS and kill task", aws: true do
      r, w = IO.pipe
      pid = fork do
        puts "exec on child process"
        r.close
        unless Wrapbox.run_cmd(["ruby -e 'sleep 120'"], environments: [{name: "RAILS_ENV", value: "development"}])
          w.write("ok")
          w.flush
        end
      end

      if pid
        w.close
        sleep 15
        puts "send SIGTERM to child process"
        Process.kill("SIGTERM", pid)
        sleep 1
        expect(r.read).to eq("ok")
      end
    end

    specify "executable on ECS with error", aws: true do
      expect {
        Wrapbox.run_cmd(["ls no_dir"], environments: [{name: "RAILS_ENV", value: "development"}])
      }.to raise_error(Wrapbox::Runner::Ecs::ExecutionFailure)
    end

    specify "executable on ECS with error, retrying", aws: true do
      expect {
        Wrapbox.run_cmd(["ls no_dir"], environments: [{name: "RAILS_ENV", value: "development"}], execution_retry: 1)
      }.to raise_error(Wrapbox::Runner::Ecs::ExecutionFailure)
    end

    specify "executable on Docker" do
      Wrapbox.run_cmd(["ls ."], config_name: :docker, environments: [{name: "RAILS_ENV", value: "development"}])
    end

    specify "executable on Docker overriding `runner`" do
      expect(Wrapbox::Runner::Docker).to receive(:new).and_call_original
      Wrapbox.run_cmd(["ls ."], runner: "docker", environments: [{name: "RAILS_ENV", value: "development"}])
    end

    specify "executable on Docker and kill task" do
      r, w = IO.pipe
      pid = fork do
        puts "exec on child process"
        r.close
        unless Wrapbox.run_cmd(["sleep 30"], config_name: :docker, environments: [{name: "RAILS_ENV", value: "development"}])
          w.write("ok")
          w.flush
        end
      end

      if pid
        w.close
        sleep 10
        puts "send SIGTERM to child process"
        Process.kill("SIGTERM", pid)
        sleep 1
        expect(r.read).to eq("ok")
      end
    end
  end
end
