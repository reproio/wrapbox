# Wrapbox

Wrapbox runs Ruby method or shell command in a container (ECS, docker).

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'wrapbox'
```

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install wrapbox

## Usage

Write config.yml

```yaml
default:
  cluster: wrapbox
  runner: ecs
  region: ap-northeast-1
  container_definitions:
    - image: joker1007/wrapbox
      cpu: 512
      memory: 1024
      essential: true

docker:
  runner: docker
  keep_container: true
  container_definitions:
    - image: joker1007/wrapbox
      cpu: 512
      memory: 1024

ecs2:
  cluster: wrapbox
  runner: ecs
  region: ap-northeast-1
  # Use already existing task definition
  task_definition:
    task_definition_name: foo_task:1
    main_container_name: container_name_where_command_is_executed
```

#### run by CLI

```sh
$ wrapbox ecs run_cmd -f config.yml \
  -e "FOO=bar,HOGE=fuga" \
  "bundle exec rspec spec/models" \
  "bundle exec rspec spec/controllers" \
```

#### run by ruby

Run `rake wrapbox:run` with `CLASS_NAME_ENV` and `METHOD_NAME_ENV` and `METHOD_ARGS_ENV`

```ruby
Wrapbox.configure do |c|
  c.load_yaml(File.expand_path("../config.yml", __FILE__))
end

# runs TestJob#perform("arg1", ["arg2", "arg3"]) in ECS container via `rake wrapbox:run`
Wrapbox.run("TestJob", :perform, ["arg1", ["arg2", "arg3"]], environments: [{name: "RAILS_ENV", value: "development"}]) # use default config
# runs TestJob#perform in local docker container (Use docker cli)
Wrapbox.run("TestJob", :perform, ["arg1", ["arg2", "arg3"]], config_name: :docker, environments: [{name: "RAILS_ENV", value: "development"}]) # use docker config

# runs ls . command in ECS container
Wrapbox.run_cmd(["ls ."], environments: [{name: "RAILS_ENV", value: "development"}])
```

## Config

### Common

| name   | desc              |
| ------ | ----------------- |
| runner | "ecs" or "docker" |

### for ECS

| name                  | desc                                                                                                        |
| --------------------  | ------------------------------------------------                                                            |
| cluster               | target ECS cluster name                                                                                     |
| region                | region of ECS cluster                                                                                       |
| container_definitions | see. http://docs.aws.amazon.com/sdkforruby/api/Aws/ECS/Client.html#register_task_definition-instance_method |
| task_role_arn         | see. http://docs.aws.amazon.com/AmazonECS/latest/developerguide/task-iam-roles.html                         |
| volumes               | see. http://docs.aws.amazon.com/sdkforruby/api/Aws/ECS/Client.html#register_task_definition-instance_method |
| placement_constraints | see. http://docs.aws.amazon.com/sdkforruby/api/Aws/ECS/Client.html#register_task_definition-instance_method |
| placement_strategy    | see. http://docs.aws.amazon.com/sdkforruby/api/Aws/ECS/Client.html#register_task_definition-instance_method |
| launch_type           | see. http://docs.aws.amazon.com/sdkforruby/api/Aws/ECS/Client.html#run_task-instance_method                 |
| network_mode          | see. http://docs.aws.amazon.com/sdkforruby/api/Aws/ECS/Client.html#register_task_definition-instance_method |
| network_configuration | see. http://docs.aws.amazon.com/sdkforruby/api/Aws/ECS/Client.html#run_task-instance_method                 |
| cpu    | see. http://docs.aws.amazon.com/sdkforruby/api/Aws/ECS/Client.html#register_task_definition-instance_method |
| memory    | see. http://docs.aws.amazon.com/sdkforruby/api/Aws/ECS/Client.html#register_task_definition-instance_method |

`WRAPBOX_CMD_INDEX` environment variable is available in `run_cmd` and you can distinguish logs from each command like below:

```
log_configuration:
  log_driver: syslog
  options:
    syslog-address: "tcp://192.168.0.42:123"
    env: WRAPBOX_CMD_INDEX
    tag: wrapbox-{{ printf "%03s" (.ExtraAttributes nil).WRAPBOX_CMD_INDEX }}
```

### for docker
| name                  | desc                                                        |
| --------------------  | ----------------------------------------------------------- |
| container_definitions | only use `image`, `cpu`, `memory`, and `memory_reservation` |
| keep_container        | If true, doesn't delete the container when the command ends |
| use_sudo              | If true, invoke `sudo docker` command                       |

## API

#### `run(class_name, method_name, args, container_definition_overrides: {}, environments: [], task_role_arn: nil, cluster: nil, timeout: 3600 * 24, launch_timeout: 60 * 10, launch_retry: 10, retry_interval: 1, retry_interval_multiplier: 2, max_retry_interval: 120, execution_retry: 0)`

#### `run_cmd(*cmd, container_definition_overrides: {}, environments: [], task_role_arn: nil, cluster: nil, timeout: 3600 * 24, launch_timeout: 60 * 10, launch_retry: 10, retry_interval: 1, retry_interval_multiplier: 2, max_retry_interval: 120, execution_retry: 0)`

following options is only for ECS.

- task_role_arn
- cluster
- timeout
- launch_timeout
- launch_retry

If Wrapbox cannot create task, it puts custom metric data to CloudWatch.
Custom metric data is `wrapbox/WaitingTaskCount` that has `ClusterName` dimension.
And, it retry launching until retry count reach `launch_retry`.

After task exited, Wrapbox checks main container exit code.
If exit code is not 0, Wrapbox raise error.

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and tags, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/reproio/wrapbox.

