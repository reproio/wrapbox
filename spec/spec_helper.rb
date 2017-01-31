$LOAD_PATH.unshift File.expand_path("../../lib", __FILE__)
require "wrapbox"

require "tapp"
require "tapp-awesome_print"

Wrapbox.configure do |c|
  c.load_yaml(File.expand_path("../config.yml", __FILE__))
end

RSpec.configure do |c|
  c.order = "random"
  c.filter_run_excluding aws: true

  c.before :each, aws: true do
    WebMock.allow_net_connect!
  end
end

if defined?(Tapp)
  Tapp.configure do |config|
    config.default_printer = :awesome_print if defined?(AwesomePrint)
    config.report_caller   = true
  end
end
