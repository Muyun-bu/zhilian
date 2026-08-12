# frozen_string_literal: true

# Optional live compatibility check. The subscription URL is passed at runtime
# and is never embedded in this file or printed in test output.
require 'tmpdir'
require_relative '../app/zhilian'

url = ARGV.fetch(0) { abort 'usage: ruby live_subscription_check.rb <subscription-url>' }
root = Dir.mktmpdir('zhilian-live-')

begin
  log = Zhilian::Log.new(File.join(root, 'live.log'))
  source_store = Zhilian::ConfigStore.new(File.join(root, 'source.json'), log)
  Zhilian::SubscriptionManager.new(source_store, log).add('live-test', url)
  nodes = source_store.snapshot['nodes'].select { |node| node['supported'] }

  results = nodes.each_with_index.map do |node, index|
    Thread.new do
      node_dir = File.join(root, "node-#{index + 1}")
      FileUtils.mkdir_p(node_dir)
      node_log = Zhilian::Log.new(File.join(node_dir, 'test.log'))
      store = Zhilian::ConfigStore.new(File.join(node_dir, 'config.json'), node_log)
      port_socket = TCPServer.new('127.0.0.1', 0)
      proxy_port = port_socket.addr[1]
      port_socket.close
      store.update do |data|
        data['nodes'] = [node]
        data['settings']['selected_node'] = node['id']
        data['settings']['mode'] = 'global'
        data['settings']['proxy_port'] = proxy_port
      end
      proxy = Zhilian::ProxyServer.new(store, Zhilian::Router.new(store), Zhilian::Stats.new, node_log)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      output = { index: index + 1, http: nil, https: nil }
      begin
        Timeout.timeout(20) do
          proxy.start
          proxy_class = Net::HTTP::Proxy('127.0.0.1', proxy_port)
          plain = proxy_class.new('example.com', 80)
          plain.open_timeout = 8
          plain.read_timeout = 8
          output[:http] = plain.get('/').code.to_i

          secure = proxy_class.new('example.com', 443)
          secure.use_ssl = true
          secure.verify_mode = OpenSSL::SSL::VERIFY_PEER
          secure.open_timeout = 8
          secure.read_timeout = 8
          output[:https] = secure.get('/').code.to_i
        end
      rescue StandardError => e
        output[:error] = e.class.to_s
      ensure
        proxy.stop
      end
      output[:latency_ms] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      output
    end
  end.map(&:value)

  summary = {
    nodes: nodes.length,
    fully_working: results.count { |row| row[:http] == 200 && row[:https] == 200 },
    results: results
  }
  puts JSON.generate(summary)
ensure
  FileUtils.remove_entry(root) if File.directory?(root)
end
