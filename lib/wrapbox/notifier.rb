module Wrapbox
  module Notifier
    class << self
      @types = {}
      def types
        @types
      end

      def register(name, klass)
        @types[name.to_sym] = klass
      end

      def get_notifier_class(name)
        @types.fetch(name.to_sym)
      end

      def build_notifier(notifier_definition)
        klass = get_notifier_class(notifier_definition.delete(:type))
        klass.new(notifier_definition)
      end
    end
  end
end
