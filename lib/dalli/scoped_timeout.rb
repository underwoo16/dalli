# frozen_string_literal: true

module Dalli
  ##
  # Per-client timeout scopes, stored in the calling fiber rather than on a
  # shared connection. Socket changes happen only while operation locks are held.
  ##
  class ScopedTimeout
    STORAGE_KEY = :dalli_socket_timeouts
    private_constant :STORAGE_KEY

    def current
      Thread.current[STORAGE_KEY]&.[](self)
    end

    def with(timeout)
      timeouts = Thread.current[STORAGE_KEY] ||= {}
      previous = timeouts[self]
      timeouts[self] = timeout
      yield
    ensure
      previous ? timeouts[self] = previous : timeouts.delete(self)
      Thread.current[STORAGE_KEY] = nil if timeouts.empty?
    end

    ##
    # Single-server operations include liveness checks before request dispatch.
    ##
    module Server
      attr_writer :timeout_context

      def request(...)
        timeout = Thread.current[STORAGE_KEY]&.[](@timeout_context)
        return super unless timeout

        synchronize_connection do
          @connection_manager.with_socket_timeout(timeout) { super }
        end
      end

      def alive?
        return true if synchronize_connection { connected? }

        timeout = Thread.current[STORAGE_KEY]&.[](@timeout_context)
        return super unless timeout

        synchronize_connection do
          @connection_manager.with_socket_timeout(timeout) { super }
        end
      end

      def with_socket_timeout(timeout, &)
        @connection_manager.with_socket_timeout(timeout, &)
      end
    end

    ##
    # A pipeline keeps its timeout through response draining and IO.select,
    # including the portions outside individual server requests.
    ##
    module Ring
      def lock(&block)
        timeout = @timeout_context.current
        return super unless timeout

        super { with_server_timeouts(timeout, 0, &block) }
      end

      private

      def with_server_timeouts(timeout, index, &block)
        return yield if index == @servers.size

        @servers[index].with_socket_timeout(timeout) do
          with_server_timeouts(timeout, index + 1, &block)
        end
      end
    end
  end
end
