require "net/http"
require "json"

module Wrapbox
  module Notifier
    class Slack < Base
      register :slack

      def initialize(title: nil, webhook_url:, color: nil)
        @webhook_uri = URI.parse(webhook_url)
        @base_options = {
          "title" => title,
          "color" => color,
          "mrkdwn_in" => ["text"],
          "short" => false,
        }
      end

      def do_notify(body:, **options)
        http = Net::HTTP.new(@webhook_uri.host)
        http.use_ssl = true
        http.ssl_version = 'TLSv1_2'

        req = Net::HTTP::Post.new(@webhook_uri.path, {"Content-Type" => "application/json"})
        req.body = JSON.generate(@base_options.merge({"text" => "```#{body}```"}))

        http.start { |session| session.request(req) }
      end
    end
  end
end
