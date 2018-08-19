module Wrapbox
  module LogFetcher
    class Papertrail
      STOP_WAIT_TIMELIMIT = 10

      def initialize(query: nil, delay: 2, **options)
        begin
          require 'papertrail/cli'
        rescue LoadError
          $stderr.puts "Require papertrail gem"
          exit 1
        end

        # see. https://github.com/papertrail/papertrail-cli/blob/master/lib/papertrail/cli.rb
        @query = query
        @delay = delay
        @options = options.reject { |_, v| v.nil? }
      end

      def run(task:)
        @started_at = Time.now
        @loop_thread = Thread.start(&method(:main_loop))
      end

      def stop
        @stop = true
        @loop_thread&.join(STOP_WAIT_TIMELIMIT)
      end

      def main_loop
        papertrail = ::Papertrail::Cli.new
        connection_options = papertrail.options.merge(@options).merge(follow: true)
        connection = ::Papertrail::Connection.new(connection_options)

        query_options = {}

        if @options[:system]
          query_options[:system_id] = connection.find_id_for_source(@options[:system])
          unless query_options[:system_id]
            $stderr.puts "System \"#{@options[:system]}\" not found"
          end
        end

        if @options[:group]
          query_options[:group_id] = connection.find_id_for_group(@options[:group])
          unless query_options[:group_id]
            $stderr.puts "Group \"#{@options[:group]}\" not found"
          end
        end

        if @options[:search]
          search = connection.find_search(@options[:search], @query_options[:group_id])
          unless search
            $stderr.puts "Search \"#{@options[:search]}\" not found"
          end

          query_options[:group_id] ||= search['group_id']
          @query = search['query']
        end

        @query ||= ''

        search_query = ::Papertrail::SearchQuery.new(connection, @query, query_options)

        until @stop do
          search_query.next_results_page.events.each do |event|
            next if event.received_at < @started_at
            papertrail.display_result(event)
          end
          sleep @delay
        end
      end
    end
  end
end
