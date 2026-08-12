# frozen_string_literal: true

# Live domestic/international split-routing check. The subscription URL is a
# runtime argument and neither the URL nor the observed egress IPs are printed.
require 'tmpdir'
require_relative '../app/zhilian'

url = ARGV.fetch(0) { abort 'usage: ruby live_split_check.rb <subscription-url>' }
root = Dir.mktmpdir('zhilian-split-')

def available_port
  socket = TCPServer.new('127.0.0.1', 0)
  port = socket.addr[1]
  socket.close
  port
end

def request_through(proxy_port, host, path = '/')
  http = Net::HTTP::Proxy('127.0.0.1', proxy_port).new(host, 443)
  http.use_ssl = true
  http.verify_mode = OpenSSL::SSL::VERIFY_PEER
  http.open_timeout = 10
  http.read_timeout = 12
  response = http.get(path)
  { code: response.code.to_i, body: response.body.to_s.strip }
rescue StandardError => e
  { code: nil, body: '', error: e.class.to_s }
end

begin
  log = Zhilian::Log.new(File.join(root, 'split.log'))
  store = Zhilian::ConfigStore.new(File.join(root, 'config.json'), log)
  Zhilian::SubscriptionManager.new(store, log).add('split-test', url)
  proxy_port = available_port
  store.update do |data|
    data['settings']['proxy_port'] = proxy_port
    data['settings']['mode'] = 'rule'
  end
  stats = Zhilian::Stats.new
  seed_path = File.expand_path('../app/data/china-ip-ranges.json', __dir__)
  ip_database = Zhilian::ChinaIPDatabase.new(root, log, seed_path: seed_path)
  proxy = Zhilian::ProxyServer.new(store, Zhilian::Router.new(store, ip_database), stats, log)
  proxy.start

  domestic = request_through(proxy_port, 'myip.ipip.net')
  international = request_through(proxy_port, 'api.ipify.org')
  baidu = request_through(proxy_port, 'www.baidu.com')
  example = request_through(proxy_port, 'example.com')

  deadline = Time.now + 3
  sleep 0.02 while stats.snapshot['recent'].length < 4 && Time.now < deadline
  records = stats.snapshot['recent']
  actions = records.each_with_object({}) { |record, memo| memo[record['host']] = record['action'] }
  categories = records.each_with_object({}) { |record, memo| memo[record['host']] = record['category'] }
  rules = records.each_with_object({}) { |record, memo| memo[record['host']] = record['rule'] }
  ip_pattern = /(?:\d{1,3}\.){3}\d{1,3}/
  domestic_ip = domestic[:body][ip_pattern].to_s
  international_ip = international[:body][ip_pattern].to_s
  output = {
    domestic: { action: actions['myip.ipip.net'], category: categories['myip.ipip.net'], rule: rules['myip.ipip.net'], http: domestic[:code], error: domestic[:error], ip_valid: !domestic_ip.empty? },
    international: { action: actions['api.ipify.org'], category: categories['api.ipify.org'], rule: rules['api.ipify.org'], http: international[:code], error: international[:error], ip_valid: !international_ip.empty? },
    representative_sites: { baidu: baidu[:code], baidu_error: baidu[:error], baidu_action: actions['www.baidu.com'], example: example[:code], example_error: example[:error], example_action: actions['example.com'] },
    egress_different: !domestic_ip.empty? && !international_ip.empty? && domestic_ip != international_ip
  }
  puts JSON.generate(output)
ensure
  proxy&.stop
  FileUtils.remove_entry(root) if File.directory?(root)
end
