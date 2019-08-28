$LOAD_PATH.unshift File.expand_path("../../lib", __FILE__)
require "wrapbox"
require "wrapbox/runner/docker"
require "wrapbox/runner/ecs"

require "tapp"
require "tapp-awesome_print"

Wrapbox.configure do |c|
  c.load_yaml(File.expand_path("../config.yml", __FILE__))
end

RSpec.configure do |c|
  c.order = "random"
  c.filter_run_excluding aws: true unless ENV["RUN_AWS_SPECS"] == "true"
end

if defined?(Tapp)
  Tapp.configure do |config|
    config.default_printer = :awesome_print if defined?(AwesomePrint)
    config.report_caller   = true
  end
end
