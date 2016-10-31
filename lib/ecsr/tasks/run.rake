require "ecsr"

namespace :ecsr do
  desc "Run Ecsr"
  task :run do
    Rake::Task["environment"].invoke if defined?(Rails)

    if ENV[Ecsr::CLASS_NAME_ENV] && ENV[Ecsr::METHOD_NAME_ENV] && ENV[Ecsr::METHOD_ARGS_ENV]
      Ecsr::Job.perform
    else
      raise "Ecsr ENVs are not found"
    end
  end
end
