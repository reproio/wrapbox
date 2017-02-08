require "thor/group"
require "wrapbox/runner/docker"
require "wrapbox/runner/ecs"

module Wrapbox
  class Cli < Thor
    register(Wrapbox::Runner::Ecs::Cli, "ecs", "ecs [COMMAND]", "Commands for ECS")
    register(Wrapbox::Runner::Docker::Cli, "docker", "docker [COMMAND]", "Commands for Docker")
  end
end
