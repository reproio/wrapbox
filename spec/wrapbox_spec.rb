require "spec_helper"

describe Wrapbox do
  it "can load yaml" do
    config = Wrapbox.configs[:default]
    expect(config.cluster).to eq("ecsr-test")
    expect(config.region).to eq("ap-northeast-1")
    expect(config.container_definition[:cpu]).to be_a(Integer)
  end

  describe ".run" do
    specify "executable on ECS", aws: true do
      Wrapbox.run("TestJob", :perform, ["arg1", ["arg2", "arg3"]], environments: [{name: "RAILS_ENV", value: "development"}])
    end

    specify "executable on Docker" do
      Wrapbox.run("TestJob", :perform, ["arg1", ["arg2", "arg3"]], config_name: :docker, environments: [{name: "RAILS_ENV", value: "development"}])
    end
  end

  describe ".run_cmd" do
    specify "executable on ECS", aws: true do
      Wrapbox.run_cmd(["ls ."], environments: [{name: "RAILS_ENV", value: "development"}])
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
  end
end
