require 'shellwords'

module Wrapbox
  module Notifier
    class Base
      class << self
        def register(name)
          Wrapbox::Notifier.register(name, self)
        end
      end

      def initialize(_definition)
        raise NotImplementedError
      end

      def notify(cmd:, environments:, definition:, **options)
        body = build_body(cmd, environments, definition)
        do_notify(body: body, **options)
      end

      private

      def do_notify(body:, **options)
        raise NotImplementedError
      end

      def build_body(cmd, environments, container_definition)
        command_string = Shellwords.shelljoin(cmd)
        environments_string = environments.map { |env| "#{env[:name]}=#{env[:value]}" }.join(" ")
        container_definition_string = container_definition.to_s
        <<~BODY
        cmd = #{command_string}
        envs = #{environments_string}
        def = #{container_definition_string}
        BODY
      end
    end
  end
end
