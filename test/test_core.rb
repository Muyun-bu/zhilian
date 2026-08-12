# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../app/zhilian'

class ZhilianCoreTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir('zhilian-test-')
    @log = Zhilian::Log.new(File.join(@tmpdir, 'test.log'))
    @store = Zhilian::ConfigStore.new(File.join(@tmpdir, 'config.json'), @log)
    @store.save
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.directory?(@tmpdir)
  end

  def test_config_updates_persist_without_deadlock
    Timeout.timeout(2) do
      @store.update { |data| data['settings']['mode'] = 'global' }
    end
    reloaded = Zhilian::ConfigStore.new(File.join(@tmpdir, 'config.json'), @log)
    assert_equal 'global', reloaded.snapshot['settings']['mode']
  end

  def test_router_uses_first_matching_rule_and_falls_back_without_node
    router = Zhilian::Router.new(@store)
    private_route = router.decide('127.0.0.1', 443)
    assert_equal 'DIRECT', private_route['action']
    assert_equal 'local', private_route['category']

    ai_without_node = router.decide('api.openai.com', 443)
    assert_equal 'DIRECT', ai_without_node['action']
    assert_includes ai_without_node['reason'], '回退直连'
    assert_equal 'DIRECT', router.decide('www.baidu.com', 443)['action']
    assert_equal 'domestic', router.decide('www.baidu.com', 443)['category']

    @store.update do |data|
      node = { 'id' => 'node-test', 'name' => 'test', 'type' => 'socks5', 'host' => '127.0.0.1', 'port' => 1, 'supported' => true }
      data['nodes'] << node
      data['settings']['selected_node'] = node['id']
    end
    assert_equal 'PROXY', router.decide('chatgpt.com', 443)['action']
    assert_equal 'PROXY', router.decide('example.com', 443)['action']
  end

  def test_ip_database_classifies_cn_and_overseas_targets_for_router
    delegated = <<~DATA
      2|apnic|20260801|3|0|20260801|20260801|+0000
      apnic|CN|ipv4|1.0.1.0|256|20260801|allocated
      apnic|CN|ipv6|2400:3200::|32|20260801|allocated
      apnic|JP|ipv4|1.0.16.0|256|20260801|allocated
    DATA
    parser = Zhilian::ChinaIPDatabase.new(@tmpdir, @log)
    File.write(File.join(@tmpdir, 'china-ip-ranges.json'), JSON.generate(parser.parse_delegated(delegated)))
    database = Zhilian::ChinaIPDatabase.new(@tmpdir, @log)
    assert_equal 'CN', database.location_for_host('1.0.1.8')
    assert_equal 'CN', database.location_for_host('2400:3200::1')
    assert_equal 'OVERSEAS', database.location_for_host('8.8.8.8')

    @store.update do |data|
      node = { 'id' => 'node-geo', 'name' => 'test', 'type' => 'socks5', 'host' => '127.0.0.1', 'port' => 1, 'supported' => true }
      data['nodes'] << node
      data['settings']['selected_node'] = node['id']
    end
    router = Zhilian::Router.new(@store, database)
    cn = router.decide('1.0.1.8', 443)
    overseas = router.decide('8.8.8.8', 443)
    assert_equal 'DIRECT', cn['action']
    assert_equal 'domestic-ip', cn['category']
    assert_equal 'PROXY', overseas['action']
    assert_equal 'international-ip', overseas['category']
  end

  def test_subscription_parses_sip002_shadowsocks_and_clash_yaml
    manager = Zhilian::SubscriptionManager.new(@store, @log)
    credentials = Base64.urlsafe_encode64('chacha20-ietf-poly1305:test-password', padding: false)
    uri_list = Base64.strict_encode64("ss://#{credentials}@127.0.0.1:8388#Local%20SS\n")
    parsed = manager.parse(uri_list, 'sub-one')
    node = parsed[:nodes].first
    assert_equal 1, parsed[:nodes].length
    assert_equal 'ss', node['type']
    assert_equal 'chacha20-ietf-poly1305', node['method']
    assert_equal 'test-password', node['password']
    assert node['supported']

    yaml = <<~YAML
      proxies:
        - name: Office HTTP
          type: http
          server: 127.0.0.1
          port: 8080
    YAML
    yaml_node = manager.parse(yaml, 'sub-two')[:nodes].first
    assert_equal 'http', yaml_node['type']
    assert yaml_node['supported']
  end

  def test_chacha20_and_poly1305_standard_vectors
    key = (0..31).to_a.pack('C*')
    nonce = ['000000090000004a00000000'].pack('H*')
    expected = '10f1e7e4d13b5915500fdd1fa32071c4c7d1f4c733c068030422aa9ac3d46c4e'
    assert Zhilian::ChaCha20Poly1305.block(key, 1, nonce).unpack1('H*').start_with?(expected)

    poly_key = ['85d6be7857556d337f4452fe42d506a80103808afb0db2fd4abff6af4149f51b'].pack('H*')
    tag = Zhilian::ChaCha20Poly1305.poly1305('Cryptographic Forum Research Group'.b, poly_key)
    assert_equal 'a8061dc1305136c6c22b8baf0c0127a9', tag.unpack1('H*')

    sealed = Zhilian::ChaCha20Poly1305.encrypt(key, nonce, 'hello'.b)
    assert_equal 'hello', Zhilian::ChaCha20Poly1305.decrypt(key, nonce, sealed)
    tampered = sealed.dup
    tampered.setbyte(0, tampered.getbyte(0) ^ 1)
    assert_raises(RuntimeError) { Zhilian::ChaCha20Poly1305.decrypt(key, nonce, tampered) }
  end

  def test_shadowsocks_socket_round_trip
    server = TCPServer.new('127.0.0.1', 0)
    password = 'round-trip-secret'
    received = Queue.new
    worker = Thread.new do
      raw = server.accept
      socket = Zhilian::ShadowsocksSocket.new(raw, password)
      destination = socket.readpartial(512)
      payload = socket.readpartial(512)
      received << [destination, payload]
      socket.write('world')
      socket.close
    end

    raw = TCPSocket.new('127.0.0.1', server.addr[1])
    client = Zhilian::ShadowsocksSocket.new(raw, password)
    client.send_destination('example.com', 443)
    client.write('hello')
    assert_equal 'world', client.readpartial(512)
    destination, payload = Timeout.timeout(2) { received.pop }
    assert_equal 3, destination.getbyte(0)
    assert_includes destination, 'example.com'
    assert_equal 'hello', payload
  ensure
    client&.close rescue nil
    server&.close rescue nil
    worker&.join(1)
    worker&.kill if worker&.alive?
  end

  def test_http_proxy_regular_and_connect_over_shadowsocks
    upstream = TCPServer.new('127.0.0.1', 0)
    password = 'proxy-chain-secret'
    upstream_worker = Thread.new do
      2.times do |index|
        raw = upstream.accept
        socket = Zhilian::ShadowsocksSocket.new(raw, password)
        socket.readpartial(512) # destination address
        if index.zero?
          request = socket.readpartial(4096)
          raise 'absolute URI was not rewritten' if request.start_with?('GET http://')
          body = 'zhilian-ok'
          socket.write("HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
        else
          payload = socket.readpartial(128)
          socket.write(payload == 'ping' ? 'pong' : 'bad')
        end
        socket.close
      end
    end

    proxy_port = available_port
    @store.update do |data|
      node = {
        'id' => 'node-ss', 'name' => 'Local SS', 'type' => 'ss', 'host' => '127.0.0.1',
        'port' => upstream.addr[1], 'password' => password, 'method' => 'chacha20-ietf-poly1305', 'supported' => true
      }
      data['nodes'] << node
      data['settings']['selected_node'] = node['id']
      data['settings']['proxy_port'] = proxy_port
      data['settings']['mode'] = 'global'
    end
    stats = Zhilian::Stats.new
    proxy = Zhilian::ProxyServer.new(@store, Zhilian::Router.new(@store), stats, @log)
    proxy.start

    http_client = TCPSocket.new('127.0.0.1', proxy_port)
    http_client.write("GET http://example.com/test HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n")
    response = read_all(http_client)
    assert_includes response, '200 OK'
    assert_includes response, 'zhilian-ok'

    tunnel = TCPSocket.new('127.0.0.1', proxy_port)
    tunnel.write("CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n")
    assert_includes read_header(tunnel), '200 Connection Established'
    tunnel.write('ping')
    assert_equal 'pong', tunnel.read(4)

    deadline = Time.now + 2
    sleep 0.02 while stats.snapshot['recent'].length < 2 && Time.now < deadline
    snapshot = stats.snapshot
    assert_equal 2, snapshot['routes']['PROXY']
    assert_operator snapshot['total_up'], :>, 0
    assert_operator snapshot['total_down'], :>, 0
  ensure
    http_client&.close rescue nil
    tunnel&.close rescue nil
    proxy&.stop
    upstream&.close rescue nil
    upstream_worker&.join(1)
    upstream_worker&.kill if upstream_worker&.alive?
  end

  def test_dashboard_assets_exist_and_brand_is_consistent
    static = File.expand_path('../app/static', __dir__)
    html = File.read(File.join(static, 'index.html'))
    assert_includes html, '<title>智连</title>'
    assert File.file?(File.join(static, 'app.js'))
    assert File.file?(File.join(static, 'styles.css'))
    refute_includes html, 'FlowPilot'
  end

  def test_subscription_add_refresh_and_remove_lifecycle
    manager = Zhilian::SubscriptionManager.new(@store, @log)
    bodies = [
      Base64.strict_encode64("http://127.0.0.1:8080#First\n"),
      Base64.strict_encode64("socks5://127.0.0.1:1080#Second\n")
    ]
    manager.define_singleton_method(:fetch) { |_url| bodies.shift }

    subscription = manager.add('Fixture', 'https://example.test/subscription')
    assert_equal 'ok', subscription['status']
    assert_equal 'http', @store.snapshot['nodes'].first['type']

    manager.refresh(subscription['id'])
    snapshot = @store.snapshot
    assert_equal 1, snapshot['nodes'].length
    assert_equal 'socks5', snapshot['nodes'].first['type']

    manager.remove(subscription['id'])
    assert_empty @store.snapshot['subscriptions']
    assert_empty @store.snapshot['nodes']
  end

  def test_admin_api_mode_node_rule_and_static_page
    static = File.expand_path('../app', __dir__)
    app = Zhilian::App.new(static, data_dir: File.join(@tmpdir, 'app-data'))
    admin = Zhilian::AdminServer.new(app, File.join(static, 'static'), @log)
    admin.start(available_port)

    health = http_json(admin.port, 'GET', '/api/health')
    assert health['ok']
    assert_equal Zhilian::VERSION, health['version']

    mode = http_json(admin.port, 'POST', '/api/mode', { mode: 'global' })
    assert_equal 'global', mode['mode']
    node = http_json(admin.port, 'POST', '/api/nodes', { type: 'http', host: '127.0.0.1', port: 3128, name: 'Fixture' })
    assert_equal 'http', node['type']
    selected = http_json(admin.port, 'POST', '/api/nodes/select', { id: node['id'] })
    assert_equal node['id'], selected['selected_node']

    rule = http_json(admin.port, 'POST', '/api/rules', { name: 'Block fixture', type: 'suffix', value: 'ads.test', action: 'REJECT' })
    toggled = http_json(admin.port, 'POST', '/api/rules/toggle', { id: rule['id'], enabled: false })
    refute toggled['enabled']
    removed = http_json(admin.port, 'DELETE', "/api/rules?id=#{rule['id']}")
    assert_equal rule['id'], removed['removed']

    response = Net::HTTP.get_response(URI("http://127.0.0.1:#{admin.port}/"))
    assert_equal '200', response.code
    assert_includes response.body.force_encoding(Encoding::UTF_8), '<title>智连</title>'
    assert_equal "default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self'; connect-src 'self'", response['content-security-policy']
  ensure
    admin&.stop
  end

  private

  def available_port
    socket = TCPServer.new('127.0.0.1', 0)
    port = socket.addr[1]
    socket.close
    port
  end

  def read_all(socket)
    output = +''
    loop { output << socket.readpartial(4096) }
  rescue EOFError, IOError, Errno::ECONNRESET
    output
  end

  def read_header(socket)
    output = +''
    output << socket.readpartial(1024) until output.include?("\r\n\r\n")
    output
  end

  def http_json(port, method, path, payload = nil)
    uri = URI("http://127.0.0.1:#{port}#{path}")
    request_class = { 'GET' => Net::HTTP::Get, 'POST' => Net::HTTP::Post, 'DELETE' => Net::HTTP::Delete }.fetch(method)
    request = request_class.new(uri)
    if payload
      request['Content-Type'] = 'application/json'
      request.body = JSON.generate(payload)
    end
    response = Net::HTTP.start(uri.host, uri.port) { |http| http.request(request) }
    assert_equal '200', response.code, response.body
    JSON.parse(response.body)
  end
end
