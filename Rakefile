require "bundler/gem_tasks"
require "rspec/core/rake_task"

load "wrapbox/tasks/run.rake"

RSpec::Core::RakeTask.new(:spec)

task :default => :spec

require_relative "./spec/test_job"
