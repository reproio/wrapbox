require "wrapbox"

namespace :wrapbox do
  desc "Run Wrapbox"
  task :run do
    Rake::Task["environment"].invoke if defined?(Rails)

    if ENV[Wrapbox::CLASS_NAME_ENV] && ENV[Wrapbox::METHOD_NAME_ENV] && ENV[Wrapbox::METHOD_ARGS_ENV]
      Wrapbox::Job.perform
    else
      raise "Wrapbox ENVs are not found"
    end
  end
end
