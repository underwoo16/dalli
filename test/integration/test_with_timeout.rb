# frozen_string_literal: true

require_relative '../helper'

describe 'scoped socket timeouts' do
  def observe_timeouts(client)
    observations = []
    client.send(:ring).servers.each do |server|
      manager = server.instance_variable_get(:@connection_manager)
      observer = Module.new do
        define_method(:read_line) do
          observations << [socket_timeout, sock.options[:socket_timeout]]
          observations.last << sock.to_io.timeout if RUBY_ENGINE == 'ruby'
          super()
        end
      end
      manager.singleton_class.prepend(observer)
    end
    observations
  end

  def assert_timeouts(observations, timeout)
    refute_empty observations
    observations.each { |values| assert_equal [timeout] * values.size, values }
    observations.clear
  end

  def with_timeout_client(options = {})
    memcached_persistent do |_, port|
      yield Dalli::Client.new("localhost:#{port}", { socket_timeout: 1 }.merge(options))
    end
  end

  def with_delayed_server(delay, fail_first: false, stall_writes: false)
    listener = TCPServer.new('127.0.0.1', 0)
    connections = Queue.new
    failed = false
    failure_lock = Mutex.new
    acceptor = Thread.new do
      loop do
        socket = listener.accept
        worker = Thread.new(socket) do |connection|
          pending = []
          while (line = connection.gets)
            words = line.split
            case words.first
            when 'version'
              connection.write("VERSION 1.6.45\r\n")
            when 'mg'
              fail_request = failure_lock.synchronize do
                if fail_first && !failed
                  failed = true
                else
                  false
                end
              end
              break if fail_request

              if words.include?('q')
                pending << words[1]
              else
                sleep delay
                connection.write("VA 1 f0\r\nv\r\n")
              end
            when 'mn'
              sleep delay
              pending.each { |key| connection.write("VA 1 f0 k#{key} c1 s1\r\nv\r\n") }
              connection.write("MN\r\n")
              pending.clear
            when 'ms'
              sleep 5 if stall_writes
            end
          end
        rescue IOError, SystemCallError
          nil
        ensure
          connection.close
        end
        connections << [socket, worker]
      end
    rescue IOError, SystemCallError
      nil
    end
    yield "127.0.0.1:#{listener.addr[1]}"
  ensure
    listener&.close
    acceptor&.kill
    acceptor&.join
    until connections.empty?
      socket, worker = connections.pop
      socket.close unless socket.closed?
      worker.kill
      worker.join
    end
  end

  it 'yields the same client, returns results, and restores a warm socket' do
    with_timeout_client do |client|
      client.set('timeout-key', 'value')
      server = client.send(:ring).servers.first
      socket = server.sock
      observations = observe_timeouts(client)

      result = client.with_timeout(5) do |scoped|
        assert_same client, scoped
        scoped.get('timeout-key')
      end

      assert_equal 'value', result
      assert_timeouts observations, 5
      assert_same socket, server.sock
      assert_equal 'value', client.get('timeout-key')
      assert_timeouts observations, 1
    end
  end

  it 'supports closure-style calls, nested scopes, and exceptional restoration' do
    with_timeout_client do |client|
      observations = observe_timeouts(client)

      client.with_timeout(5) do
        client.get('missing')

        assert_timeouts observations, 5
        assert_raises(RuntimeError) do
          client.with_timeout(2) do
            client.get('missing')

            assert_timeouts observations, 2
            raise 'leave the inner scope'
          end
        end
        client.get('missing')

        assert_timeouts observations, 5
      end

      assert_raises(RuntimeError) { client.with_timeout(3) { raise 'leave the outer scope' } }
      client.get('missing')

      assert_timeouts observations, 1
    end
  end

  it 'restores the timeout after a break' do
    with_timeout_client do |client|
      assert_equal :stopped, client.with_timeout(5) { break :stopped }
      observations = observe_timeouts(client)
      client.get('missing')

      assert_timeouts observations, 1
    end
  end

  it 'restores the timeout after cancellation outside StandardError' do
    with_timeout_client do |client|
      # rubocop:disable-next Lint/InheritException
      cancellation = Class.new(Exception)
      client.get('missing')
      manager = client.send(:ring).servers.first.instance_variable_get(:@connection_manager)

      manager.stub(:read_line, -> { raise cancellation }) do
        assert_raises(cancellation) { client.with_timeout(5) { client.get('missing') } }
      end

      assert_nil manager.sock
      observations = observe_timeouts(client)
      client.get('missing')

      assert_timeouts observations, 1
    end
  end

  it 'allows slow reads and multi-gets only within the longer timeout scope' do
    with_delayed_server(0.12) do |address|
      client = Dalli::Client.new(address, socket_timeout: 0.04, enforce_read_timeout: true,
                                          socket_failure_delay: 0, socket_max_failures: 1)
      client.with_timeout(0.5) do
        assert_equal 'v', client.get('a')
        assert_equal({ 'a' => 'v', 'b' => 'v' }, client.get_multi(%w[a b]))
        assert_equal %w[a b], client.get_multi_cas(%w[a b]).keys.sort
      end

      assert_raises(Dalli::NetworkError) { client.get('a') }
    end
  end

  it 'enforces a shorter timeout and restores the original limit after failure' do
    with_delayed_server(0.12) do |address|
      client = Dalli::Client.new(address, socket_timeout: 1, enforce_read_timeout: true,
                                          socket_failure_delay: 0, socket_max_failures: 1, down_retry_delay: 0)

      assert_raises(Dalli::NetworkError) { client.with_timeout(0.04) { client.get('a') } }
      assert_equal 'v', client.get('a')
    end
  end

  it 'keeps the override during an automatic retry on a fresh connection' do
    with_delayed_server(0.12, fail_first: true) do |address|
      client = Dalli::Client.new(address, socket_timeout: 0.04, enforce_read_timeout: true, socket_failure_delay: 0)
      observations = observe_timeouts(client)

      assert_equal 'v', client.with_timeout(0.5) { client.get('a') }
      assert_timeouts observations, 0.5
      assert_in_delta(0.04, client.send(:ring).socket_timeout)
    end
  end

  it 'times out a blocked write before trying to read its reply' do
    skip 'reliable IO write timeouts require CRuby' unless RUBY_ENGINE == 'ruby'

    with_delayed_server(0, stall_writes: true) do |address|
      client = Dalli::Client.new(address, socket_timeout: 1, socket_max_failures: 1, socket_failure_delay: 0,
                                          raw: true, sndbuf: 4096, value_max_bytes: 32 * 1024 * 1024)
      client.alive!
      observations = observe_timeouts(client)

      assert_raises(Dalli::NetworkError) do
        client.with_timeout(0.04) { client.set('large', 'x' * (16 * 1024 * 1024)) }
      end
      assert_empty observations
      assert_equal 1, client.send(:ring).socket_timeout
    end
  end

  it 'restores an unbounded socket timeout' do
    with_timeout_client(socket_timeout: nil) do |client|
      observations = observe_timeouts(client)
      client.with_timeout(0.5) { client.get('missing') }

      assert_timeouts observations, 0.5
      client.get('missing')

      assert_timeouts observations, nil
    end
  end

  it 'does not affect another client in the same fiber' do
    with_timeout_client do |client|
      other = Dalli::Client.new(client.send(:ring).servers.first.name, socket_timeout: 3)
      observations = observe_timeouts(client)
      other_observations = observe_timeouts(other)

      client.with_timeout(5) do
        client.get('missing')
        other.get('missing')
      end

      assert_timeouts observations, 5
      assert_timeouts other_observations, 3
    end
  end

  it 'supports a non-threadsafe client used by one caller' do
    with_timeout_client(threadsafe: false) do |client|
      observations = observe_timeouts(client)
      client.with_timeout(5) { client.get('missing') }

      assert_timeouts observations, 5
      client.get('missing')

      assert_timeouts observations, 1
    end
  end

  it 'does not leak to another thread or hold locks across user code' do
    with_timeout_client do |client|
      observations = observe_timeouts(client)
      client.with_timeout(5) do
        worker = Thread.new { client.get('missing') }

        assert worker.join(5), 'another caller was blocked by the timeout block'
        assert_timeouts observations, 1
        client.get('missing')

        assert_timeouts observations, 5
      ensure
        worker&.kill
        worker&.join
      end
    end
  end

  it 'does not leak to another fiber on the same thread' do
    with_timeout_client do |client|
      observations = observe_timeouts(client)
      client.with_timeout(5) do
        Fiber.new { client.get('missing') }.resume

        assert_timeouts observations, 1
        client.get('missing')

        assert_timeouts observations, 5
      end
    end
  end

  it 'configures new sockets and sockets created after a reset within the scope' do
    with_timeout_client do |client|
      client.with_timeout(5) do
        observations = observe_timeouts(client)
        client.get('missing')

        assert_timeouts observations, 5
        client.close
        observations = observe_timeouts(client)
        client.get('missing')

        assert_timeouts observations, 5
      end
      observations = observe_timeouts(client)
      client.get('missing')

      assert_timeouts observations, 1
    end
  end

  it 'preserves an explicit connect timeout and scopes its fallback on reconnects' do
    [nil, 0.25].each do |connect_timeout|
      with_timeout_client(connect_timeout: connect_timeout) do |client|
        received = []
        original = Dalli::Socket::TCP.method(:create_socket_with_timeout)
        intercept = lambda do |host, port, options, &block|
          received << Dalli::Socket.connect_timeout_for(options)
          original.call(host, port, options, &block)
        end

        Dalli::Socket::TCP.stub(:create_socket_with_timeout, intercept) do
          client.with_timeout(5) do
            client.get('missing')
            client.send(:ring).servers.first.close
            client.get('missing')
          end
        end

        assert_equal [connect_timeout || 5] * 2, received
      end
    end
  end

  it 'keeps the override through all multi-get response waits' do
    with_one_and_two_servers(:meta) do |client|
      client.set_multi('timeout-a' => 'a', 'timeout-b' => 'b')
      timeouts = []
      select = IO.method(:select)
      intercept = lambda do |readers, writers, errors, timeout|
        timeouts << timeout
        select.call(readers, writers, errors, timeout)
      end

      IO.stub(:select, intercept) do
        result = client.with_timeout(5) do |scoped|
          scoped.get_multi(%w[timeout-a timeout-b]) { |_, _| nil }
          scoped.get_multi_cas(%w[timeout-a timeout-b])
        end

        assert_equal %w[timeout-a timeout-b], result.keys.sort
      end

      refute_empty timeouts
      assert_equal [5], timeouts.uniq
      assert_equal 1, client.send(:ring).socket_timeout
    end
  end

  it 'scopes bulk writes, metadata reads, and quiet response draining' do
    with_one_and_two_servers(:meta) do |client|
      observations = observe_timeouts(client)
      client.with_timeout(5) do
        client.set_multi('timeout-a' => 'a', 'timeout-b' => 'b')

        assert_equal 'a', client.get_multi_with_metadata('timeout-a').fetch('timeout-a')[:value]
        client.quiet { client.set('timeout-c', 'c') }
        client.delete_multi(%w[timeout-a timeout-b])
      end

      assert_timeouts observations, 5
      assert_equal 'c', client.get('timeout-c')
      assert_timeouts observations, 1
    end
  end

  it 'drains deferred replies using the timeout of the later operation' do
    with_timeout_client(defer_drain: true) do |client|
      observations = observe_timeouts(client)
      client.with_timeout(5) { client.quiet { client.set('timeout-deferred', 'value') } }
      observations.clear

      assert_equal 'value', client.get('timeout-deferred')
      assert_timeouts observations, 1
    end
  end

  it 'reuses TLS connections and restores their underlying socket timeout' do
    memcached_ssl_persistent do |client|
      observations = observe_timeouts(client)
      socket = client.send(:ring).servers.first.sock

      client.with_timeout(5) { assert_nil client.get('missing') }
      assert_timeouts observations, 5
      assert_same socket, client.send(:ring).servers.first.sock
      client.get('missing')

      assert_timeouts observations, 1
    end
  end

  it 'uses the scoped timeout during a new TLS handshake' do
    memcached_ssl_persistent do |client|
      client.send(:ring).servers.each(&:close)
      handshakes = []
      original = Dalli::Socket::TCP.method(:wrapping_ssl_socket)
      intercept = lambda do |socket, host, context|
        handshakes << socket.options[:socket_timeout]
        original.call(socket, host, context)
      end

      Dalli::Socket::TCP.stub(:wrapping_ssl_socket, intercept) do
        client.with_timeout(0.5) { assert_nil client.get('missing') }
      end

      assert_equal [0.5], handshakes
      assert_equal 1, client.send(:ring).socket_timeout
    end
  end

  it 'scopes UNIX socket operations' do
    skip 'UNIX sockets unsupported on Windows' if RbConfig::CONFIG['host_os'].match?(/mingw|mswin/)

    Dir.mktmpdir do |directory|
      memcached(:meta, File.join(directory, 'timeout.sock')) do |client|
        observations = observe_timeouts(client)
        client.with_timeout(5) { client.get('missing') }

        assert_timeouts observations, 5
        client.get('missing')

        assert_timeouts observations, 1
      end
    end
  end

  it 'rejects invalid durations before connecting or entering the block' do
    client = Dalli::Client.new('localhost:1')

    [nil, false, '5', 0, -1, Float::INFINITY, Float::NAN, Complex(1, 1)].each do |timeout|
      assert_raises(ArgumentError) { client.with_timeout(timeout) { flunk 'invalid timeout entered the block' } }
    end
    assert_nil client.instance_variable_get(:@ring)
    assert_raises(ArgumentError) { client.with_timeout(5) }
  end
end
