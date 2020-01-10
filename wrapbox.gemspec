# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'wrapbox/version'

Gem::Specification.new do |spec|
  spec.name          = "wrapbox"
  spec.version       = Wrapbox::VERSION
  spec.authors       = ["joker1007"]
  spec.email         = ["kakyoin.hierophant@gmail.com"]

  spec.summary       = %q{Ruby method runner on AWS ECS}
  spec.description   = %q{Ruby method runner on AWS ECS}
  spec.homepage      = ""

  spec.files         = `git ls-files -z`.split("\x0").reject do |f|
    f.match(%r{^(test|spec|features)/})
  end
  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_runtime_dependency "aws-sdk-ec2", "~> 1"
  spec.add_runtime_dependency "aws-sdk-ecs", "~> 1"
  spec.add_runtime_dependency "aws-sdk-cloudwatch", "~> 1"
  spec.add_runtime_dependency "activesupport", ">= 4"
  spec.add_runtime_dependency "docker-api"
  spec.add_runtime_dependency "multi_json"
  spec.add_runtime_dependency "thor"

  spec.add_development_dependency "bundler"
  spec.add_development_dependency "rake"
  spec.add_development_dependency "rspec", "~> 3.0"
  spec.add_development_dependency "webmock"
  spec.add_development_dependency "tapp"
  spec.add_development_dependency "tapp-awesome_print"
end
