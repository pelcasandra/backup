module Backup
  # Provides cascading errors with formatted messages.
  # See the specs for details.
  module NestedExceptions
    def self.included(klass)
      klass.extend(Module.new do
        def wrap(wrapped_exception, msg = nil)
          new(msg, wrapped_exception)
        end
      end)
    end

    def initialize(obj = nil, wrapped_exception = nil)
      @wrapped_exception = wrapped_exception
      msg = (obj.respond_to?(:to_str) ? obj.to_str : obj.to_s)
        .gsub(/^ */, "  ").strip
      msg = clean_name(self.class.name) + (msg.empty? ? "" : ": #{msg}")

      if wrapped_exception
        msg << "\n--- Wrapped Exception ---\n"
        class_name = clean_name(wrapped_exception.class.name)
        msg << class_name + ": " unless
            wrapped_exception.message.start_with? class_name
        msg << wrapped_exception.message
      end

      super(msg)
      set_backtrace(wrapped_exception.backtrace) if wrapped_exception
    end

    def exception(obj = nil)
      return self if obj.nil? || equal?(obj)

      ex = self.class.new(obj, @wrapped_exception)
      ex.set_backtrace(backtrace) unless ex.backtrace
      ex
    end

    private

    def clean_name(name)
      name.sub(/^Backup::/, "")
    end
  end

  class Error < StandardError
    include NestedExceptions
  end

  class FatalError < Exception
    include NestedExceptions
  end

  module Path
    class Error < Backup::Error; end

    class << self
      def component(value, label)
        value = value.to_s
        raise_invalid(label) if invalid_component?(value)
        value
      end

      def join_within(root, *components, label:)
        relative_path = join_components(*components, label:)
        expand_within(root, relative_path, label)
      end

      def join_components(*components, label:)
        raise_invalid(label) if components.empty?

        components.map { component(it, label) }.join(File::SEPARATOR)
      end

      def relative_file(root, value, label)
        value = value.to_s
        raise_invalid(label) if invalid_relative_path?(value)

        realpath_within(root, File.expand_path(value, root), label)
      end

      def realpath_within(root, value, label)
        root = File.realpath(root)
        path = File.realpath(value)
        raise_escape(label) unless within?(root, path)
        path
      end

      def expand_within(root, value, label)
        root = File.expand_path(root)
        path = File.expand_path(value, root)
        raise_escape(label) unless within?(root, path)
        path
      end

      private

      def within?(root, path)
        prefix = root == File::SEPARATOR ? root : root + File::SEPARATOR
        path == root || path.start_with?(prefix)
      end

      def invalid_component?(value)
        value.empty? || value == "." || value.include?("..") ||
          value.include?("/") || value.include?("\\") || value.include?("\0")
      end

      def invalid_relative_path?(value)
        value.empty? || value == "." || value.start_with?("/") ||
          value.include?("..") || value.include?("\\") || value.include?("\0")
      end

      def raise_invalid(label)
        raise Error, <<-EOS
          Invalid #{label}
          #{label} must stay within its intended directory and may not be empty,
          '.', contain '..', or contain path separators.
        EOS
      end

      def raise_escape(label)
        raise Error, <<-EOS
          Invalid #{label}
          #{label} must stay within its intended directory.
        EOS
      end
    end
  end
end
