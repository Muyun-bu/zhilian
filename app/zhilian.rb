#!/usr/bin/env ruby
# frozen_string_literal: true

Encoding.default_external = Encoding::UTF_8

require 'base64'
require 'cgi'
require 'digest'
require 'fileutils'
require 'ipaddr'
require 'json'
require 'net/http'
require 'open3'
require 'openssl'
require 'resolv'
require 'securerandom'
require 'socket'
require 'time'
require 'timeout'
require 'uri'
require 'yaml'

module Zhilian
  VERSION = '0.2.0'
  APP_NAME = '智连'

  def self.utf8(value)
    string = value.to_s.dup
    string.force_encoding(Encoding::UTF_8)
    return string if string.valid_encoding?
    string.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: '�')
  end

  class Log
    def initialize(path)
      @path = path
      @mutex = Mutex.new
    end

    def write(level, message)
      line = "#{Time.now.utc.iso8601} [#{level.upcase}] #{message}\n"
      @mutex.synchronize do
        File.open(@path, 'a') { |file| file.write(line) }
      end
    rescue StandardError
      nil
    end

    def info(message); write('info', message); end
    def warn(message); write('warn', message); end
    def error(message); write('error', message); end
  end

  class ConfigStore
    DEFAULT_RULES = [
      { 'id' => 'builtin-private', 'name' => '局域网与本机', 'type' => 'private', 'value' => '', 'action' => 'DIRECT', 'enabled' => true, 'builtin' => true },
      { 'id' => 'builtin-cn', 'name' => '中国域名', 'type' => 'suffix', 'value' => '.cn', 'action' => 'DIRECT', 'enabled' => true, 'builtin' => true },
      { 'id' => 'builtin-domestic', 'name' => '国内常用服务', 'type' => 'category', 'value' => 'domestic', 'action' => 'DIRECT', 'enabled' => true, 'builtin' => true },
      { 'id' => 'builtin-ai', 'name' => 'AI 服务', 'type' => 'category', 'value' => 'ai', 'action' => 'PROXY', 'enabled' => true, 'builtin' => true },
      { 'id' => 'builtin-streaming', 'name' => '流媒体', 'type' => 'category', 'value' => 'streaming', 'action' => 'PROXY', 'enabled' => true, 'builtin' => true },
      { 'id' => 'builtin-social', 'name' => '国际社交', 'type' => 'category', 'value' => 'social', 'action' => 'PROXY', 'enabled' => true, 'builtin' => true },
      { 'id' => 'builtin-geo-cn', 'name' => '中国服务器 IP', 'type' => 'geoip', 'value' => 'CN', 'action' => 'DIRECT', 'enabled' => true, 'builtin' => true },
      { 'id' => 'builtin-geo-overseas', 'name' => '境外服务器 IP', 'type' => 'geoip', 'value' => 'OVERSEAS', 'action' => 'PROXY', 'enabled' => true, 'builtin' => true },
      { 'id' => 'builtin-international', 'name' => '其他国际流量', 'type' => 'match', 'value' => '*', 'action' => 'PROXY', 'enabled' => true, 'builtin' => true }
    ].freeze

    DEFAULT = {
      'version' => 1,
      'settings' => {
        'proxy_port' => 7890,
        'dashboard_port' => 9090,
        'mode' => 'rule',
        'proxy_enabled' => true,
        'selected_node' => nil
      },
      'nodes' => [],
      'subscriptions' => [],
      'rules' => DEFAULT_RULES
    }.freeze

    attr_reader :data

    def initialize(path, log)
      @path = path
      @log = log
      @mutex = Mutex.new
      @data = load_data
    end

    def save
      @mutex.synchronize { persist_unlocked }
    end

    def update
      @mutex.synchronize do
        yield @data
        persist_unlocked
      end
    end

    def snapshot
      @mutex.synchronize { Marshal.load(Marshal.dump(@data)) }
    end

    private

    def persist_unlocked
      tmp = "#{@path}.tmp"
      File.write(tmp, JSON.pretty_generate(@data))
      File.rename(tmp, @path)
    end

    def load_data
      return Marshal.load(Marshal.dump(DEFAULT)) unless File.file?(@path)

      parsed = JSON.parse(File.read(@path))
      merged = Marshal.load(Marshal.dump(DEFAULT))
      merged['version'] = parsed['version'] || 1
      merged['settings'].merge!(parsed['settings'] || {})
      merged['nodes'] = parsed['nodes'] || []
      merged['subscriptions'] = parsed['subscriptions'] || []
      custom_rules = (parsed['rules'] || []).reject { |rule| rule['builtin'] }
      builtin_overrides = (parsed['rules'] || []).select { |rule| rule['builtin'] }.each_with_object({}) { |rule, memo| memo[rule['id']] = rule }
      merged['rules'] = DEFAULT_RULES.map { |rule| builtin_overrides[rule['id']] || Marshal.load(Marshal.dump(rule)) } + custom_rules
      merged
    rescue StandardError => e
      @log.warn("配置读取失败，已使用默认值: #{e.message}")
      Marshal.load(Marshal.dump(DEFAULT))
    end
  end

  class ChinaIPDatabase
    SOURCE_URL = 'https://ftp.apnic.net/stats/apnic/delegated-apnic-latest'
    CACHE_TTL = 300

    def initialize(data_dir, log, seed_path: nil)
      @path = File.join(data_dir, 'china-ip-ranges.json')
      @log = log
      @mutex = Mutex.new
      @dns_cache = {}
      FileUtils.cp(seed_path, @path) if seed_path && !File.file?(@path) && File.file?(seed_path)
      load_database
    end

    def ready?
      @mutex.synchronize { !@ipv4.empty? || !@ipv6.empty? }
    end

    def status
      @mutex.synchronize do
        {
          'ready' => !@ipv4.empty? || !@ipv6.empty?,
          'updated_at' => @metadata['updated_at'],
          'source_date' => @metadata['source_date'],
          'ipv4_ranges' => @ipv4.length,
          'ipv6_ranges' => @ipv6.length,
          'source' => 'APNIC'
        }
      end
    end

    def location_for_host(host)
      target = host.to_s.downcase.sub(/\.$/, '')
      ip = IPAddr.new(target)
      return ip.private? || ip.loopback? || ip.link_local? ? 'PRIVATE' : location_for_ip(ip)
    rescue IPAddr::InvalidAddressError
      cached = @mutex.synchronize { @dns_cache[target] }
      return cached['location'] if cached && cached['expires_at'] > Time.now.to_i
      addresses = Timeout.timeout(2) { Resolv.getaddresses(target) }
      location = addresses.empty? ? 'UNKNOWN' : location_for_ip(IPAddr.new(addresses.first))
      @mutex.synchronize do
        @dns_cache[target] = { 'location' => location, 'expires_at' => Time.now.to_i + CACHE_TTL }
        @dns_cache.shift if @dns_cache.length > 2_000
      end
      location
    rescue StandardError
      'UNKNOWN'
    end

    def location_for_ip(ip)
      ranges = @mutex.synchronize { ip.ipv4? ? @ipv4 : @ipv6 }
      contains?(ranges, ip.to_i) ? 'CN' : 'OVERSEAS'
    end

    def update
      body = fetch(SOURCE_URL)
      parsed = parse_delegated(body)
      raise 'APNIC 数据中没有有效的中国 IP 段' if parsed['ipv4'].empty? || parsed['ipv6'].empty?
      save_database(parsed)
      load_database
      @log.info("中国 IP 段库更新完成：IPv4 #{parsed['ipv4'].length}，IPv6 #{parsed['ipv6'].length}")
      status
    end

    def parse_delegated(body)
      ipv4 = []
      ipv6 = []
      source_date = nil
      body.to_s.each_line do |line|
        next if line.start_with?('#')
        fields = line.strip.split('|')
        next unless fields.length >= 7 && fields[1] == 'CN' && %w[allocated assigned].include?(fields[6])
        source_date = fields[5] if fields[5] && fields[5] > source_date.to_s
        if fields[2] == 'ipv4'
          start_value = IPAddr.new(fields[3]).to_i
          count = fields[4].to_i
          ipv4 << [start_value, start_value + count - 1] if count.positive?
        elsif fields[2] == 'ipv6'
          network = IPAddr.new("#{fields[3]}/#{fields[4]}")
          ipv6 << [network.to_range.begin.to_i, network.to_range.end.to_i]
        end
      rescue IPAddr::InvalidAddressError
        next
      end
      {
        'version' => 1, 'source' => SOURCE_URL, 'source_date' => source_date,
        'updated_at' => Time.now.utc.iso8601, 'ipv4' => merge_ranges(ipv4), 'ipv6' => merge_ranges(ipv6)
      }
    end

    private

    def load_database
      data = File.file?(@path) ? JSON.parse(File.read(@path)) : {}
      @mutex.synchronize do
        @ipv4 = data['ipv4'] || []
        @ipv6 = data['ipv6'] || []
        @metadata = data
      end
    rescue StandardError => e
      @log.warn("中国 IP 段库读取失败: #{e.message}")
      @mutex.synchronize do
        @ipv4 = []
        @ipv6 = []
        @metadata = {}
      end
    end

    def save_database(data)
      tmp = "#{@path}.tmp"
      File.write(tmp, JSON.generate(data))
      File.rename(tmp, @path)
    end

    def merge_ranges(ranges)
      ranges.sort_by!(&:first)
      ranges.each_with_object([]) do |range, merged|
        if !merged.empty? && range[0] <= merged[-1][1] + 1
          merged[-1][1] = [merged[-1][1], range[1]].max
        else
          merged << range.dup
        end
      end
    end

    def contains?(ranges, value)
      low = 0
      high = ranges.length - 1
      while low <= high
        middle = (low + high) / 2
        range = ranges[middle]
        return true if value >= range[0] && value <= range[1]
        value < range[0] ? high = middle - 1 : low = middle + 1
      end
      false
    end

    def fetch(url, redirects = 3)
      raise 'IP 段库重定向次数过多' if redirects.negative?
      uri = URI.parse(url)
      request = Net::HTTP::Get.new(uri)
      request['User-Agent'] = "Zhilian/#{VERSION}"
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', open_timeout: 10, read_timeout: 25) { |http| http.request(request) }
      return fetch(URI.join(uri, response['location']).to_s, redirects - 1) if response.is_a?(Net::HTTPRedirection)
      raise "APNIC 返回 HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
      raise 'APNIC 数据过大' if response.body.bytesize > 12 * 1024 * 1024
      response.body
    end
  end

  class Stats
    MAX_RECENT = 200

    def initialize
      @mutex = Mutex.new
      @active = {}
      @recent = []
      @total_up = 0
      @total_down = 0
      @last_up = 0
      @last_down = 0
      @series = Array.new(60) { { 'up' => 0, 'down' => 0, 'at' => Time.now.to_i } }
      @started_at = Time.now
      @routes = Hash.new(0)
    end

    def open(meta)
      id = SecureRandom.hex(5)
      record = meta.merge(
        'id' => id,
        'started_at' => Time.now.utc.iso8601,
        'up' => 0,
        'down' => 0,
        'status' => 'active'
      )
      @mutex.synchronize do
        @active[id] = record
        @routes[record['action']] += 1
      end
      id
    end

    def add(id, direction, bytes)
      @mutex.synchronize do
        record = @active[id]
        return unless record
        if direction == :up
          record['up'] += bytes
          @total_up += bytes
        else
          record['down'] += bytes
          @total_down += bytes
        end
      end
    end

    def close(id, status = 'closed', error = nil)
      @mutex.synchronize do
        record = @active.delete(id)
        return unless record
        record['status'] = status
        record['error'] = error if error
        record['ended_at'] = Time.now.utc.iso8601
        @recent.unshift(record)
        @recent = @recent.take(MAX_RECENT)
      end
    end

    def tick
      @mutex.synchronize do
        @series.shift
        @series << {
          'up' => @total_up - @last_up,
          'down' => @total_down - @last_down,
          'at' => Time.now.to_i
        }
        @last_up = @total_up
        @last_down = @total_down
      end
    end

    def snapshot
      @mutex.synchronize do
        {
          'active' => @active.values.sort_by { |row| row['started_at'] }.reverse,
          'recent' => @recent.take(60),
          'total_up' => @total_up,
          'total_down' => @total_down,
          'series' => @series.dup,
          'routes' => @routes.dup,
          'uptime' => (Time.now - @started_at).to_i
        }
      end
    end
  end

  class Router
    CATEGORY_DOMAINS = {
      'domestic' => %w[baidu.com qq.com wechat.com weixin.qq.com taobao.com tmall.com jd.com bilibili.com douyin.com zhihu.com weibo.com csdn.net aliyun.com 163.com sina.com.cn xiaomi.com meituan.com amap.com alipay.com],
      'ai' => %w[openai.com chatgpt.com anthropic.com claude.ai perplexity.ai huggingface.co midjourney.com],
      'streaming' => %w[youtube.com youtu.be netflix.com spotify.com hulu.com disneyplus.com twitch.tv vimeo.com],
      'social' => %w[twitter.com x.com facebook.com instagram.com telegram.org t.me reddit.com discord.com],
      'developer' => %w[github.com githubusercontent.com npmjs.com docker.com stackoverflow.com]
    }.freeze

    def initialize(store, ip_database = nil)
      @store = store
      @ip_database = ip_database
    end

    def classify(host, port)
      value = host.to_s.downcase.sub(/\.$/, '')
      category = CATEGORY_DOMAINS.find { |_name, domains| domains.any? { |domain| value == domain || value.end_with?(".#{domain}") } }
      return category[0] if category
      return 'local' if private_host?(value)
      return 'web' if [80, 443, 8080, 8443].include?(port.to_i)
      'other'
    end

    def decide(host, port)
      config = @store.snapshot
      settings = config['settings']
      category = classify(host, port)
      mode = settings['mode']

      return result('DIRECT', '直连模式', category, config) if mode == 'direct'
      return result('PROXY', '全局模式', category, config) if mode == 'global'

      config['rules'].each do |rule|
        next unless rule['enabled']
        next unless matches?(rule, host, port, category)
        routed_category = if rule['type'] == 'geoip'
                            rule['value'] == 'CN' ? 'domestic-ip' : 'international-ip'
                          else
                            category
                          end
        return result(rule['action'], rule['name'] || rule['value'], routed_category, config, rule['id'])
      end

      result('DIRECT', '默认规则', category, config)
    end

    private

    def matches?(rule, host, port, category)
      value = rule['value'].to_s.downcase
      target = host.to_s.downcase.sub(/\.$/, '')
      case rule['type']
      when 'private' then private_host?(target)
      when 'domain' then target == value
      when 'suffix'
        suffix = value.sub(/^\./, '')
        target == suffix || target.end_with?(".#{suffix}")
      when 'keyword' then target.include?(value)
      when 'regex' then Regexp.new(value, Regexp::IGNORECASE).match?(target)
      when 'port' then port.to_i == value.to_i
      when 'cidr'
        IPAddr.new(value).include?(IPAddr.new(target))
      when 'category' then category == value
      when 'geoip' then @ip_database && @ip_database.location_for_host(target) == rule['value'].to_s.upcase
      when 'match' then true
      else false
      end
    rescue StandardError
      false
    end

    def private_host?(host)
      return true if host == 'localhost' || host.end_with?('.local')
      ip = IPAddr.new(host)
      ip.private? || ip.loopback? || ip.link_local?
    rescue IPAddr::InvalidAddressError
      false
    end

    def result(action, reason, category, config, rule_id = nil)
      node = nil
      final_action = action.to_s.upcase
      if final_action == 'PROXY'
        node = config['nodes'].find { |item| item['id'] == config['settings']['selected_node'] && item['supported'] != false }
        unless node
          final_action = 'DIRECT'
          reason = "#{reason} · 无可用节点，回退直连"
        end
      elsif !%w[DIRECT REJECT].include?(final_action)
        node = config['nodes'].find { |item| item['id'] == action && item['supported'] != false }
        final_action = node ? 'PROXY' : 'DIRECT'
      end
      { 'action' => final_action, 'node' => node, 'reason' => reason, 'category' => category, 'rule_id' => rule_id }
    end
  end

  class SubscriptionManager
    SUPPORTED_TYPES = %w[http socks5 ss].freeze
    SUPPORTED_SS_METHODS = %w[chacha20-ietf-poly1305].freeze

    def initialize(store, log)
      @store = store
      @log = log
    end

    def add(name, url)
      uri = validated_uri(url)
      id = "sub-#{SecureRandom.hex(4)}"
      subscription = { 'id' => id, 'name' => name.to_s.strip.empty? ? uri.host : name.to_s.strip, 'url' => uri.to_s, 'updated_at' => nil, 'node_ids' => [], 'status' => 'pending' }
      @store.update { |data| data['subscriptions'] << subscription }
      refresh(id)
    end

    def refresh(id)
      subscription = @store.snapshot['subscriptions'].find { |item| item['id'] == id }
      raise '订阅不存在' unless subscription

      body = fetch(subscription['url'])
      parsed = parse(body, id)
      now = Time.now.utc.iso8601
      @store.update do |data|
        current = data['subscriptions'].find { |item| item['id'] == id }
        old_ids = current['node_ids'] || []
        data['nodes'].reject! { |node| old_ids.include?(node['id']) }
        data['nodes'].concat(parsed[:nodes])
        current['node_ids'] = parsed[:nodes].map { |node| node['id'] }
        current['updated_at'] = now
        current['status'] = 'ok'
        current['error'] = nil
        current['node_count'] = parsed[:nodes].length
        selected = data['settings']['selected_node']
        available_ids = data['nodes'].select { |node| node['supported'] != false }.map { |node| node['id'] }
        data['settings']['selected_node'] = available_ids.first unless available_ids.include?(selected)
      end
      @log.info("订阅 #{subscription['name']} 更新完成，共 #{parsed[:nodes].length} 个节点")
      @store.snapshot['subscriptions'].find { |item| item['id'] == id }
    rescue StandardError => e
      @store.update do |data|
        current = data['subscriptions'].find { |item| item['id'] == id }
        if current
          current['status'] = 'error'
          current['error'] = e.message
        end
      end
      @log.warn("订阅更新失败: #{e.message}")
      raise
    end

    def remove(id)
      @store.update do |data|
        subscription = data['subscriptions'].find { |item| item['id'] == id }
        raise '订阅不存在' unless subscription
        ids = subscription['node_ids'] || []
        data['nodes'].reject! { |node| ids.include?(node['id']) }
        data['subscriptions'].reject! { |item| item['id'] == id }
        if ids.include?(data['settings']['selected_node'])
          fallback = data['nodes'].find { |node| node['supported'] != false }
          data['settings']['selected_node'] = fallback && fallback['id']
        end
      end
    end

    def parse(body, source_id)
      stripped = body.to_s.strip
      parsed = parse_json(stripped, source_id) || parse_yaml(stripped, source_id) || parse_uri_list(stripped, source_id)
      raise '未识别到任何节点；当前支持 HTTP 与 SOCKS5 节点' if parsed[:nodes].empty?
      parsed
    end

    private

    def validated_uri(url)
      uri = URI.parse(url.to_s.strip)
      raise '订阅地址仅支持 http:// 或 https://' unless %w[http https].include?(uri.scheme)
      raise '订阅地址缺少主机名' if uri.host.to_s.empty?
      uri
    rescue URI::InvalidURIError
      raise '订阅地址格式无效'
    end

    def fetch(url)
      uri = validated_uri(url)
      request = Net::HTTP::Get.new(uri)
      request['User-Agent'] = "Zhilian/#{VERSION}"
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', open_timeout: 8, read_timeout: 15) { |http| http.request(request) }
      raise "订阅服务器返回 HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
      raise '订阅内容过大（上限 5 MB）' if response.body.bytesize > 5 * 1024 * 1024
      response.body
    end

    def parse_json(text, source_id)
      data = JSON.parse(text)
      list = data.is_a?(Array) ? data : data['nodes'] || data['proxies']
      return nil unless list.is_a?(Array)
      { nodes: list.map { |item| normalize_node(item, source_id) }.compact }
    rescue JSON::ParserError, TypeError
      nil
    end

    def parse_yaml(text, source_id)
      data = YAML.safe_load(text, [], [], false)
      return nil unless data.is_a?(Hash) && data['proxies'].is_a?(Array)
      { nodes: data['proxies'].map { |item| normalize_node(item, source_id) }.compact }
    rescue Psych::Exception, ArgumentError
      nil
    end

    def parse_uri_list(text, source_id)
      decoded = maybe_decode_base64(text)
      nodes = decoded.lines.map(&:strip).reject { |line| line.empty? || line.start_with?('#') }.map do |line|
        parse_node_uri(line, source_id)
      end.compact
      { nodes: nodes }
    end

    def maybe_decode_base64(text)
      return text if text.include?('://') || text.include?("\n-")
      Base64.strict_decode64(text.gsub(/\s+/, ''))
    rescue ArgumentError
      text
    end

    def parse_node_uri(line, source_id)
      return parse_ss_uri(line, source_id) if line.start_with?('ss://')
      uri = URI.parse(line)
      type = uri.scheme.to_s.downcase
      return unsupported_uri(line, source_id, type) unless SUPPORTED_TYPES.include?(type)
      name = uri.fragment ? Zhilian.utf8(CGI.unescape(uri.fragment)) : "#{type.upcase} #{uri.host}:#{uri.port}"
      normalize_node({
        'name' => name,
        'type' => type,
        'server' => uri.host,
        'port' => uri.port,
        'username' => uri.user && CGI.unescape(uri.user),
        'password' => uri.password && CGI.unescape(uri.password)
      }, source_id)
    rescue URI::InvalidURIError, URI::InvalidComponentError
      nil
    end

    def parse_ss_uri(line, source_id)
      raw = line.sub(/\Ass:\/\//, '')
      payload, fragment = raw.split('#', 2)
      payload, query = payload.split('?', 2)
      return unsupported_uri(line, source_id, 'ss') if query && query.include?('plugin=')

      if payload.include?('@')
        encoded_credentials, server_part = payload.split('@', 2)
        credentials = decode_urlsafe(encoded_credentials)
      else
        decoded = decode_urlsafe(payload)
        credentials, server_part = decoded.split('@', 2)
      end
      method, password = credentials.to_s.split(':', 2)
      host, port = split_server(server_part)
      name = fragment ? Zhilian.utf8(CGI.unescape(fragment)) : "SS #{host}:#{port}"
      normalize_node({
        'name' => name, 'type' => 'ss', 'server' => host, 'port' => port,
        'method' => method, 'password' => password,
        'supported' => SUPPORTED_SS_METHODS.include?(method)
      }, source_id)
    rescue StandardError
      nil
    end

    def decode_urlsafe(value)
      Base64.urlsafe_decode64(value.to_s + ('=' * ((4 - value.to_s.length % 4) % 4)))
    rescue ArgumentError
      CGI.unescape(value.to_s)
    end

    def split_server(value)
      text = value.to_s
      if text.start_with?('[')
        match = text.match(/\A\[([^\]]+)\]:(\d+)\z/)
        return [match[1], match[2].to_i] if match
      end
      host, port = text.rpartition(':').values_at(0, 2)
      [host, port.to_i]
    end

    def unsupported_uri(line, source_id, type)
      return nil unless %w[ss vmess vless trojan hysteria hysteria2 tuic].include?(type)
      id = "node-#{Digest::SHA256.hexdigest(line)[0, 12]}"
      { 'id' => id, 'name' => "#{type.upcase} 节点", 'type' => type, 'source_id' => source_id, 'supported' => false, 'disabled_reason' => '此轻量内核暂不支持该协议' }
    end

    def normalize_node(item, source_id)
      return nil unless item.is_a?(Hash)
      type = (item['type'] || item[:type]).to_s.downcase
      host = item['server'] || item[:server] || item['host'] || item[:host]
      port = item['port'] || item[:port]
      name = item['name'] || item[:name] || "#{type.upcase} #{host}:#{port}"
      fingerprint = [source_id, type, host, port, name].join('|')
      explicitly_supported = item.key?('supported') ? item['supported'] : item[:supported]
      supported = explicitly_supported.nil? ? SUPPORTED_TYPES.include?(type) : !!explicitly_supported
      supported &&= SUPPORTED_SS_METHODS.include?((item['method'] || item[:method]).to_s) if type == 'ss'
      node = {
        'id' => "node-#{Digest::SHA256.hexdigest(fingerprint)[0, 12]}",
        'name' => Zhilian.utf8(name),
        'type' => type,
        'host' => host.to_s,
        'port' => port.to_i,
        'username' => item['username'] || item[:username],
        'password' => item['password'] || item[:password],
        'method' => item['method'] || item[:method],
        'source_id' => source_id,
        'supported' => supported
      }
      node['disabled_reason'] = type == 'ss' ? "暂不支持 SS 加密方法 #{node['method']}" : '此轻量内核暂不支持该协议' unless node['supported']
      return nil if node['host'].empty? || node['port'].zero?
      node
    end
  end

  # Minimal RFC 8439 implementation used by the built-in Shadowsocks AEAD client.
  # Keeping it here avoids shipping a native dependency in the macOS application.
  class ChaCha20Poly1305
    TAG_SIZE = 16
    MASK32 = 0xffff_ffff

    def self.encrypt(key, nonce, plaintext, aad = ''.b)
      poly_key = block(key, 0, nonce).byteslice(0, 32)
      ciphertext = xor_stream(key, nonce, plaintext.b, 1)
      [ciphertext, poly1305(poly_input(aad.b, ciphertext), poly_key)].join
    end

    def self.decrypt(key, nonce, sealed, aad = ''.b)
      raise 'AEAD 数据长度无效' if sealed.bytesize < TAG_SIZE
      ciphertext = sealed.byteslice(0, sealed.bytesize - TAG_SIZE)
      received = sealed.byteslice(-TAG_SIZE, TAG_SIZE)
      poly_key = block(key, 0, nonce).byteslice(0, 32)
      expected = poly1305(poly_input(aad.b, ciphertext), poly_key)
      raise 'AEAD 认证失败' unless secure_compare(received, expected)
      xor_stream(key, nonce, ciphertext, 1)
    end

    def self.block(key, counter, nonce)
      raise 'ChaCha20 密钥长度无效' unless key.bytesize == 32
      raise 'ChaCha20 nonce 长度无效' unless nonce.bytesize == 12
      state = [0x61707865, 0x3320646e, 0x79622d32, 0x6b206574] + key.unpack('V8') + [counter & MASK32] + nonce.unpack('V3')
      working = state.dup
      10.times do
        quarter_round(working, 0, 4, 8, 12)
        quarter_round(working, 1, 5, 9, 13)
        quarter_round(working, 2, 6, 10, 14)
        quarter_round(working, 3, 7, 11, 15)
        quarter_round(working, 0, 5, 10, 15)
        quarter_round(working, 1, 6, 11, 12)
        quarter_round(working, 2, 7, 8, 13)
        quarter_round(working, 3, 4, 9, 14)
      end
      working.each_index { |index| working[index] = (working[index] + state[index]) & MASK32 }
      working.pack('V16')
    end

    def self.poly1305(message, one_time_key)
      raise 'Poly1305 密钥长度无效' unless one_time_key.bytesize == 32
      r = little_integer(one_time_key.byteslice(0, 16)) & 0x0ffffffc0ffffffc0ffffffc0fffffff
      s = little_integer(one_time_key.byteslice(16, 16))
      modulus = (1 << 130) - 5
      accumulator = 0
      message.bytes.each_slice(16) do |slice|
        block_value = little_integer(slice.pack('C*')) + (1 << (slice.length * 8))
        accumulator = ((accumulator + block_value) * r) % modulus
      end
      little_bytes((accumulator + s) & ((1 << 128) - 1), 16)
    end

    def self.xor_stream(key, nonce, input, initial_counter)
      output = +''.b
      input.bytes.each_slice(64).with_index do |slice, index|
        stream = block(key, initial_counter + index, nonce).bytes
        output << slice.each_with_index.map { |byte, offset| byte ^ stream[offset] }.pack('C*')
      end
      output
    end

    def self.poly_input(aad, ciphertext)
      aad + padding(aad.bytesize) + ciphertext + padding(ciphertext.bytesize) + [aad.bytesize, ciphertext.bytesize].pack('Q<Q<')
    end

    def self.padding(length)
      remainder = length % 16
      remainder.zero? ? ''.b : ("\x00" * (16 - remainder)).b
    end

    def self.quarter_round(words, a, b, c, d)
      words[a] = (words[a] + words[b]) & MASK32
      words[d] = rotate(words[d] ^ words[a], 16)
      words[c] = (words[c] + words[d]) & MASK32
      words[b] = rotate(words[b] ^ words[c], 12)
      words[a] = (words[a] + words[b]) & MASK32
      words[d] = rotate(words[d] ^ words[a], 8)
      words[c] = (words[c] + words[d]) & MASK32
      words[b] = rotate(words[b] ^ words[c], 7)
    end

    def self.rotate(value, bits)
      ((value << bits) & MASK32) | (value >> (32 - bits))
    end

    def self.little_integer(bytes)
      bytes.bytes.each_with_index.reduce(0) { |value, (byte, index)| value | (byte << (index * 8)) }
    end

    def self.little_bytes(value, length)
      Array.new(length) { |index| (value >> (index * 8)) & 0xff }.pack('C*')
    end

    def self.secure_compare(left, right)
      return false unless left.bytesize == right.bytesize
      difference = 0
      left.bytes.zip(right.bytes) { |a, b| difference |= a ^ b }
      difference.zero?
    end

    private_class_method :xor_stream, :poly_input, :padding, :quarter_round, :rotate, :little_integer, :little_bytes, :secure_compare
  end

  class ShadowsocksSocket
    MAX_CHUNK = 0x3fff
    KEY_SIZE = 32

    def initialize(socket, password)
      @socket = socket
      @master_key = evp_bytes_to_key(password.to_s.b, KEY_SIZE)
      @write_mutex = Mutex.new
      @read_buffer = +''.b
      @write_nonce = 0
      @read_nonce = 0
    end

    def send_destination(host, port)
      address = encode_address(host, port)
      write(address)
    end

    def write(data)
      payload = data.to_s.b
      @write_mutex.synchronize do
        start_writer unless @write_key
        payload.bytes.each_slice(MAX_CHUNK) do |slice|
          chunk = slice.pack('C*')
          length = [chunk.bytesize].pack('n')
          @socket.write(ChaCha20Poly1305.encrypt(@write_key, next_write_nonce, length))
          @socket.write(ChaCha20Poly1305.encrypt(@write_key, next_write_nonce, chunk))
        end
      end
      payload.bytesize
    end

    def readpartial(max_length)
      return take_buffer(max_length) unless @read_buffer.empty?
      start_reader unless @read_key
      encrypted_length = read_exact(2 + ChaCha20Poly1305::TAG_SIZE)
      length_data = ChaCha20Poly1305.decrypt(@read_key, next_read_nonce, encrypted_length)
      length = length_data.unpack1('n')
      raise 'SS 数据帧长度无效' unless length.between?(1, MAX_CHUNK)
      encrypted_payload = read_exact(length + ChaCha20Poly1305::TAG_SIZE)
      @read_buffer << ChaCha20Poly1305.decrypt(@read_key, next_read_nonce, encrypted_payload)
      take_buffer(max_length)
    end

    def close
      @socket.close
    end

    def to_io
      @socket
    end

    private

    def start_writer
      salt = SecureRandom.random_bytes(KEY_SIZE)
      @write_key = derive_subkey(salt)
      @socket.write(salt)
    end

    def start_reader
      salt = read_exact(KEY_SIZE)
      @read_key = derive_subkey(salt)
    end

    def take_buffer(max_length)
      output = @read_buffer.byteslice(0, max_length)
      @read_buffer = @read_buffer.byteslice(output.bytesize, @read_buffer.bytesize - output.bytesize) || +''.b
      output
    end

    def read_exact(length)
      output = +''.b
      output << @socket.readpartial(length - output.bytesize) while output.bytesize < length
      output
    end

    def next_write_nonce
      value = nonce_bytes(@write_nonce)
      @write_nonce += 1
      value
    end

    def next_read_nonce
      value = nonce_bytes(@read_nonce)
      @read_nonce += 1
      value
    end

    def nonce_bytes(counter)
      [counter & 0xffff_ffff_ffff_ffff].pack('Q<') + [(counter >> 64) & 0xffff_ffff].pack('V')
    end

    def derive_subkey(salt)
      pseudo_random_key = OpenSSL::HMAC.digest('sha1', salt, @master_key)
      output = +''.b
      previous = +''.b
      counter = 1
      while output.bytesize < KEY_SIZE
        previous = OpenSSL::HMAC.digest('sha1', pseudo_random_key, previous + 'ss-subkey'.b + [counter].pack('C'))
        output << previous
        counter += 1
      end
      output.byteslice(0, KEY_SIZE)
    end

    def evp_bytes_to_key(password, length)
      output = +''.b
      previous = +''.b
      while output.bytesize < length
        previous = Digest::MD5.digest(previous + password)
        output << previous
      end
      output.byteslice(0, length)
    end

    def encode_address(host, port)
      ip = IPAddr.new(host)
      type = ip.ipv4? ? 1 : 4
      [type].pack('C') + ip.hton + [port].pack('n')
    rescue IPAddr::InvalidAddressError
      value = host.to_s.b
      raise '目标域名过长' if value.bytesize > 255
      [3, value.bytesize].pack('CC') + value + [port].pack('n')
    end
  end

  class ProxyServer
    attr_reader :running, :error

    def initialize(store, router, stats, log)
      @store = store
      @router = router
      @stats = stats
      @log = log
      @running = false
      @server = nil
      @threads = []
    end

    def start
      return if @running
      port = @store.snapshot['settings']['proxy_port'].to_i
      @server = TCPServer.new('127.0.0.1', port)
      @running = true
      @error = nil
      @accept_thread = Thread.new do
        while @running
          begin
            client = @server.accept
            @threads.reject! { |thread| !thread.alive? }
            @threads << Thread.new(client) { |socket| handle(socket) }
          rescue IOError, Errno::EBADF
            break
          rescue StandardError => e
            @log.warn("代理接入异常: #{e.message}")
          end
        end
      end
      @log.info("代理已监听 127.0.0.1:#{port}")
    rescue StandardError => e
      @running = false
      @error = e.message
      @log.error("代理启动失败: #{e.message}")
      raise
    end

    def stop
      @running = false
      @server&.close
      @server = nil
      @log.info('代理已停止')
    rescue StandardError
      nil
    end

    def test_node(node)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      socket = Timeout.timeout(10) do
        connection = connect_destination('example.com', 80, node)
        connection.write("HEAD / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n")
        response = connection.readpartial(128)
        raise '节点未返回有效的 HTTP 响应' unless response.start_with?('HTTP/')
        connection
      end
      socket.close
      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    end

    private

    def handle(client)
      client.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
      header = read_header(client)
      return if header.nil? || header.empty?
      request_line, *header_lines = header.split("\r\n")
      method, target, version = request_line.to_s.split(' ', 3)
      raise '请求格式无效' unless method && target && version
      headers = parse_headers(header_lines)
      host, port = destination(method, target, headers)
      decision = @router.decide(host, port)
      record_id = @stats.open(
        'host' => host, 'port' => port, 'method' => method, 'action' => decision['action'],
        'node' => decision['node'] && decision['node']['name'], 'rule' => decision['reason'], 'category' => decision['category']
      )

      if decision['action'] == 'REJECT'
        client.write("HTTP/1.1 403 Forbidden\r\nConnection: close\r\nContent-Length: 0\r\n\r\n")
        @stats.close(record_id, 'rejected')
        return
      end

      remote = connect_destination(host, port, decision['node'])
      if method.upcase == 'CONNECT'
        client.write("HTTP/1.1 200 Connection Established\r\nProxy-Agent: Zhilian/#{VERSION}\r\n\r\n")
      else
        outgoing = rewrite_request(method, target, version, header_lines)
        remote.write(outgoing)
        @stats.add(record_id, :up, outgoing.bytesize)
      end
      relay(client, remote, record_id)
      @stats.close(record_id)
    rescue StandardError => e
      begin
        client.write("HTTP/1.1 502 Bad Gateway\r\nContent-Type: text/plain; charset=utf-8\r\nConnection: close\r\nContent-Length: #{e.message.bytesize}\r\n\r\n#{e.message}")
      rescue StandardError
        nil
      end
      @stats.close(record_id, 'error', e.message) if defined?(record_id) && record_id
      @log.warn("连接处理失败: #{e.message}")
    ensure
      remote&.close rescue nil
      client&.close rescue nil
    end

    def read_header(socket)
      buffer = +''
      until buffer.include?("\r\n\r\n")
        chunk = socket.readpartial(4096)
        buffer << chunk
        raise '请求头过大' if buffer.bytesize > 65_536
      end
      head, rest = buffer.split("\r\n\r\n", 2)
      socket.instance_variable_set(:@zhilian_prefetched, rest)
      "#{head}\r\n"
    rescue EOFError
      nil
    end

    def parse_headers(lines)
      lines.each_with_object({}) do |line, memo|
        key, value = line.split(':', 2)
        memo[key.downcase] = value.to_s.strip if key && value
      end
    end

    def destination(method, target, headers)
      if method.upcase == 'CONNECT'
        host, port = split_host_port(target, 443)
      elsif target =~ %r{\Ahttps?://}i
        uri = URI.parse(target)
        host = uri.host
        port = uri.port
      else
        host, port = split_host_port(headers['host'], 80)
      end
      raise '无法识别目标主机' if host.to_s.empty?
      [host, port]
    end

    def split_host_port(value, default_port)
      text = value.to_s
      if text.start_with?('[')
        match = text.match(/\A\[([^\]]+)\](?::(\d+))?\z/)
        return [match[1], (match[2] || default_port).to_i] if match
      end
      host, port = text.split(':', 2)
      [host, (port || default_port).to_i]
    end

    def rewrite_request(method, target, version, header_lines)
      path = target
      if target =~ %r{\Ahttps?://}i
        uri = URI.parse(target)
        path = uri.request_uri
      end
      filtered = header_lines.reject { |line| line =~ /\AProxy-(Connection|Authorization):/i }
      "#{method} #{path} #{version}\r\n#{filtered.join("\r\n")}\r\n\r\n"
    end

    def connect_destination(host, port, node)
      return Timeout.timeout(10) { TCPSocket.new(host, port) } unless node
      case node['type']
      when 'http' then connect_http_proxy(node, host, port)
      when 'socks5' then connect_socks5(node, host, port)
      when 'ss' then connect_shadowsocks(node, host, port)
      else raise "不支持的节点协议: #{node['type']}"
      end
    end

    def connect_shadowsocks(node, host, port)
      raise "不支持的 SS 加密方法: #{node['method']}" unless node['method'] == 'chacha20-ietf-poly1305'
      socket = Timeout.timeout(10) { TCPSocket.new(node['host'], node['port']) }
      wrapped = ShadowsocksSocket.new(socket, node['password'])
      wrapped.send_destination(host, port)
      wrapped
    rescue StandardError
      socket&.close rescue nil
      raise
    end

    def connect_http_proxy(node, host, port)
      socket = Timeout.timeout(10) { TCPSocket.new(node['host'], node['port']) }
      auth = if node['username'] && !node['username'].to_s.empty?
               token = Base64.strict_encode64("#{node['username']}:#{node['password']}")
               "Proxy-Authorization: Basic #{token}\r\n"
             else
               ''
             end
      socket.write("CONNECT #{host}:#{port} HTTP/1.1\r\nHost: #{host}:#{port}\r\n#{auth}Connection: keep-alive\r\n\r\n")
      response = read_until(socket, "\r\n\r\n", 16_384)
      raise '上游 HTTP 代理拒绝连接' unless response.lines.first.to_s =~ %r{HTTP/\d\.\d 2\d\d}
      socket
    end

    def connect_socks5(node, host, port)
      socket = Timeout.timeout(10) { TCPSocket.new(node['host'], node['port']) }
      if node['username'] && !node['username'].to_s.empty?
        socket.write("\x05\x02\x00\x02")
      else
        socket.write("\x05\x01\x00")
      end
      version, method = socket.read(2).bytes
      raise 'SOCKS5 握手失败' unless version == 5 && method != 255
      if method == 2
        username = node['username'].to_s.b
        password = node['password'].to_s.b
        socket.write([1, username.bytesize].pack('CC') + username + [password.bytesize].pack('C') + password)
        auth_version, status = socket.read(2).bytes
        raise 'SOCKS5 用户名或密码错误' unless auth_version == 1 && status.zero?
      end
      host_bytes = host.to_s.b
      socket.write([5, 1, 0, 3, host_bytes.bytesize].pack('CCCCC') + host_bytes + [port].pack('n'))
      reply = socket.read(4)
      raise 'SOCKS5 连接响应无效' unless reply && reply.bytesize == 4
      version, status, _reserved, address_type = reply.bytes
      raise "SOCKS5 节点连接失败（#{status}）" unless version == 5 && status.zero?
      case address_type
      when 1 then socket.read(4)
      when 3 then socket.read(socket.read(1).unpack1('C'))
      when 4 then socket.read(16)
      end
      socket.read(2)
      socket
    rescue StandardError
      socket&.close rescue nil
      raise
    end

    def read_until(socket, marker, limit)
      buffer = +''
      until buffer.include?(marker)
        buffer << socket.readpartial(1024)
        raise '上游响应过大' if buffer.bytesize > limit
      end
      buffer
    end

    def relay(client, remote, id)
      prefetched = client.instance_variable_get(:@zhilian_prefetched)
      if prefetched && !prefetched.empty?
        remote.write(prefetched)
        @stats.add(id, :up, prefetched.bytesize)
      end
      completed = Queue.new
      workers = [
        Thread.new do
          loop do
            data = client.readpartial(16_384)
            remote.write(data)
            @stats.add(id, :up, data.bytesize)
          end
        rescue EOFError, IOError, Errno::ECONNRESET, Errno::EPIPE
          nil
        ensure
          completed << true
        end,
        Thread.new do
          loop do
            data = remote.readpartial(16_384)
            client.write(data)
            @stats.add(id, :down, data.bytesize)
          end
        rescue EOFError, IOError, Errno::ECONNRESET, Errno::EPIPE
          nil
        ensure
          completed << true
        end
      ]
      completed.pop
      client.close rescue nil
      remote.close rescue nil
      workers.each { |worker| worker.join(0.5) }
      workers.each { |worker| worker.kill if worker.alive? }
    end
  end

  class SystemProxy
    def initialize(store, log)
      @store = store
      @log = log
      @enabled = false
      @service = nil
    end

    def status
      if !@last_checked || Time.now - @last_checked > 5
        service = active_service
        if service
          output, = Open3.capture3('/usr/sbin/networksetup', '-getwebproxy', service)
          enabled = output[/Enabled:\s*(\S+)/, 1].to_s.casecmp('yes').zero?
          server = output[/Server:\s*(\S+)/, 1]
          port = output[/Port:\s*(\d+)/, 1].to_i
          expected_port = @store.snapshot['settings']['proxy_port'].to_i
          @enabled = enabled && server == '127.0.0.1' && port == expected_port
          @service = service
        end
        @last_checked = Time.now
      end
      { 'enabled' => @enabled, 'service' => @service }
    rescue StandardError
      { 'enabled' => @enabled, 'service' => @service }
    end

    def set(enabled)
      service = active_service
      raise '无法识别当前网络服务' unless service
      port = @store.snapshot['settings']['proxy_port'].to_s
      if enabled
        run_networksetup('-setwebproxy', service, '127.0.0.1', port)
        run_networksetup('-setsecurewebproxy', service, '127.0.0.1', port)
        run_networksetup('-setwebproxystate', service, 'on')
        run_networksetup('-setsecurewebproxystate', service, 'on')
      else
        run_networksetup('-setwebproxystate', service, 'off')
        run_networksetup('-setsecurewebproxystate', service, 'off')
      end
      @enabled = enabled
      @service = service
      @last_checked = Time.now
      @log.info("系统代理#{enabled ? '已启用' : '已关闭'}: #{service}")
      status
    end

    private

    def active_service
      route_output, = Open3.capture3('/sbin/route', '-n', 'get', 'default')
      interface = route_output[/interface:\s*(\S+)/, 1]
      output, = Open3.capture3('/usr/sbin/networksetup', '-listnetworkserviceorder')
      current = nil
      output.each_line do |line|
        current = line.sub(/^\(\d+\)\s*/, '').strip if line =~ /^\(\d+\)/
        return current if interface && line.include?("Device: #{interface}")
      end
      nil
    end

    def run_networksetup(*args)
      _out, error, status = Open3.capture3('/usr/sbin/networksetup', *args)
      raise(error.strip.empty? ? '系统代理设置失败' : error.strip) unless status.success?
    end
  end

  class AdminServer
    MIME = {
      '.html' => 'text/html; charset=utf-8', '.css' => 'text/css; charset=utf-8',
      '.js' => 'application/javascript; charset=utf-8', '.svg' => 'image/svg+xml',
      '.json' => 'application/json; charset=utf-8', '.png' => 'image/png'
    }.freeze

    attr_reader :port

    def initialize(app, static_dir, log)
      @app = app
      @static_dir = Zhilian.utf8(static_dir)
      @log = log
    end

    def start(preferred_port)
      @port, @server = bind_available(preferred_port)
      @thread = Thread.new do
        loop do
          client = @server.accept
          Thread.new(client) { |socket| handle(socket) }
        rescue IOError, Errno::EBADF
          break
        rescue StandardError => e
          @log.warn("面板服务异常: #{e.message}")
        end
      end
      @log.info("控制面板已监听 127.0.0.1:#{@port}")
    end

    def stop
      @server&.close
    rescue StandardError
      nil
    end

    private

    def bind_available(preferred)
      (preferred.to_i..preferred.to_i + 20).each do |candidate|
        begin
          return [candidate, TCPServer.new('127.0.0.1', candidate)]
        rescue Errno::EADDRINUSE
          next
        end
      end
      raise '没有可用的控制面板端口'
    end

    def handle(socket)
      request = read_request(socket)
      return unless request
      method = request[:method]
      uri = URI.parse(request[:target])
      path = uri.path
      query = CGI.parse(uri.query.to_s)

      if path.start_with?('/api/')
        result = dispatch_api(method, path, query, request[:body])
        respond_json(socket, 200, result)
      else
        serve_static(socket, path)
      end
    rescue StandardError => e
      @log.warn("API 请求失败: #{e.message} | #{Array(e.backtrace).take(4).join(' <- ')}")
      respond_json(socket, 400, { 'error' => e.message }) rescue nil
    ensure
      socket.close rescue nil
    end

    def read_request(socket)
      buffer = +''
      until buffer.include?("\r\n\r\n")
        buffer << socket.readpartial(4096)
        raise '请求头过大' if buffer.bytesize > 65_536
      end
      head, remainder = buffer.split("\r\n\r\n", 2)
      lines = head.split("\r\n")
      method, target, = lines.shift.to_s.split(' ', 3)
      headers = lines.each_with_object({}) do |line, memo|
        key, value = line.split(':', 2)
        memo[key.downcase] = value.to_s.strip if key && value
      end
      length = headers['content-length'].to_i
      body = remainder || ''
      body << socket.read(length - body.bytesize) if body.bytesize < length
      { method: method, target: target, headers: headers, body: body.byteslice(0, length) }
    rescue EOFError
      nil
    end

    def dispatch_api(method, path, query, body)
      payload = body.to_s.empty? ? {} : JSON.parse(body)
      case [method, path]
      when ['GET', '/api/health'] then { 'ok' => true, 'version' => VERSION }
      when ['GET', '/api/snapshot'] then @app.snapshot
      when ['POST', '/api/mode'] then @app.set_mode(payload['mode'])
      when ['POST', '/api/proxy/toggle'] then @app.toggle_proxy(payload['enabled'])
      when ['POST', '/api/system-proxy'] then @app.system_proxy.set(payload['enabled'])
      when ['POST', '/api/nodes/select'] then @app.select_node(payload['id'])
      when ['POST', '/api/nodes/test'] then @app.test_node(payload['id'])
      when ['POST', '/api/nodes'] then @app.add_node(payload)
      when ['POST', '/api/subscriptions'] then @app.subscriptions.add(payload['name'], payload['url'])
      when ['POST', '/api/subscriptions/refresh'] then @app.subscriptions.refresh(payload['id'])
      when ['DELETE', '/api/subscriptions'] then @app.subscriptions.remove(query.fetch('id', []).first)
      when ['POST', '/api/rules'] then @app.add_rule(payload)
      when ['POST', '/api/rules/toggle'] then @app.toggle_rule(payload['id'], payload['enabled'])
      when ['DELETE', '/api/rules'] then @app.remove_rule(query.fetch('id', []).first)
      when ['POST', '/api/ip-database/update'] then @app.update_ip_database
      when ['POST', '/api/shutdown'] then @app.request_shutdown
      else raise '接口不存在'
      end
    end

    def serve_static(socket, path)
      path = Zhilian.utf8(path)
      path = '/index.html' if path == '/'
      clean = File.expand_path(path.sub(%r{\A/}, ''), @static_dir)
      root = File.expand_path(@static_dir)
      return respond_text(socket, 403, 'Forbidden') unless clean.start_with?("#{root}/")
      return respond_text(socket, 404, 'Not Found') unless File.file?(clean)
      data = File.binread(clean)
      respond(socket, 200, MIME.fetch(File.extname(clean), 'application/octet-stream'), data)
    end

    def respond_json(socket, status, object)
      respond(socket, status, 'application/json; charset=utf-8', JSON.generate(object))
    end

    def respond_text(socket, status, text)
      respond(socket, status, 'text/plain; charset=utf-8', text)
    end

    def respond(socket, status, content_type, body)
      names = { 200 => 'OK', 400 => 'Bad Request', 403 => 'Forbidden', 404 => 'Not Found' }
      socket.write("HTTP/1.1 #{status} #{names[status]}\r\nContent-Type: #{content_type}\r\nContent-Length: #{body.bytesize}\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self'; connect-src 'self'\r\nConnection: close\r\n\r\n")
      socket.write(body)
    end
  end

  class App
    attr_reader :subscriptions, :system_proxy

    def initialize(resource_dir, data_dir: nil)
      @resource_dir = Zhilian.utf8(resource_dir)
      @data_dir = data_dir || ENV['ZHILIAN_DATA_DIR'] || File.expand_path('~/Library/Application Support/Zhilian')
      FileUtils.mkdir_p(@data_dir)
      @log = Log.new(File.join(@data_dir, 'zhilian.log'))
      @store = ConfigStore.new(File.join(@data_dir, 'config.json'), @log)
      @store.save
      @stats = Stats.new
      seed_path = File.join(@resource_dir, 'data', 'china-ip-ranges.json')
      @ip_database = ChinaIPDatabase.new(@data_dir, @log, seed_path: seed_path)
      @router = Router.new(@store, @ip_database)
      @subscriptions = SubscriptionManager.new(@store, @log)
      @proxy = ProxyServer.new(@store, @router, @stats, @log)
      @system_proxy = SystemProxy.new(@store, @log)
      @admin = AdminServer.new(self, File.join(@resource_dir, 'static'), @log)
    end

    def run(open_browser: true)
      settings = @store.snapshot['settings']
      begin
        @proxy.start if settings['proxy_enabled']
      rescue StandardError
        nil
      end
      @admin.start(settings['dashboard_port'])
      @tick_thread = Thread.new do
        loop do
          sleep 1
          @stats.tick
        end
      end
      Thread.new { sleep 0.5; system('/usr/bin/open', "http://127.0.0.1:#{@admin.port}") } if open_browser
      trap('TERM') { shutdown }
      trap('INT') { shutdown }
      sleep
    ensure
      shutdown
    end

    def shutdown
      return if @shutting_down
      @shutting_down = true
      begin
        @system_proxy.set(false) if @system_proxy.status['enabled']
      rescue StandardError => e
        @log.warn("退出时关闭系统代理失败: #{e.message}")
      end
      @proxy.stop
      @admin.stop
      exit
    rescue SystemExit
      raise
    rescue StandardError
      exit
    end

    def request_shutdown
      Thread.new do
        sleep 0.15
        Process.kill('TERM', Process.pid)
      end
      { 'ok' => true }
    end

    def update_ip_database
      @ip_database.update
    end

    def snapshot
      config = @store.snapshot
      config['settings'] = config['settings'].merge(
        'proxy_running' => @proxy.running,
        'proxy_error' => @proxy.error,
        'dashboard_port' => @admin.port,
        'system_proxy' => @system_proxy.status
      )
      { 'version' => VERSION, 'config' => config, 'stats' => @stats.snapshot, 'ip_database' => @ip_database.status }
    end

    def set_mode(mode)
      raise '模式无效' unless %w[rule global direct].include?(mode)
      @store.update { |data| data['settings']['mode'] = mode }
      { 'mode' => mode }
    end

    def toggle_proxy(enabled)
      if enabled
        @proxy.start
      else
        @proxy.stop
      end
      @store.update { |data| data['settings']['proxy_enabled'] = !!enabled }
      { 'enabled' => @proxy.running }
    end

    def select_node(id)
      node = @store.snapshot['nodes'].find { |item| item['id'] == id }
      raise '节点不存在' unless node
      raise(node['disabled_reason'] || '节点不可用') if node['supported'] == false
      @store.update { |data| data['settings']['selected_node'] = id }
      { 'selected_node' => id }
    end

    def test_node(id)
      node = @store.snapshot['nodes'].find { |item| item['id'] == id }
      raise '节点不存在' unless node
      raise(node['disabled_reason'] || '节点不可用') if node['supported'] == false
      latency = @proxy.test_node(node)
      { 'id' => id, 'latency' => latency }
    end

    def add_node(payload)
      type = payload['type'].to_s.downcase
      raise '手动添加仅支持 HTTP 或 SOCKS5 节点；SS 请通过订阅导入' unless %w[http socks5].include?(type)
      raise '节点地址不能为空' if payload['host'].to_s.empty?
      port = payload['port'].to_i
      raise '节点端口无效' unless port.between?(1, 65_535)
      id = "node-#{SecureRandom.hex(6)}"
      node = {
        'id' => id, 'name' => payload['name'].to_s.empty? ? "#{type.upcase} #{payload['host']}:#{port}" : payload['name'].to_s,
        'type' => type, 'host' => payload['host'].to_s, 'port' => port,
        'username' => payload['username'], 'password' => payload['password'], 'supported' => true, 'source_id' => 'manual'
      }
      @store.update do |data|
        data['nodes'] << node
        data['settings']['selected_node'] ||= id
      end
      node
    end

    def add_rule(payload)
      type = payload['type'].to_s
      action = payload['action'].to_s.upcase
      raise '规则类型无效' unless %w[domain suffix keyword regex port cidr category].include?(type)
      raise '规则动作无效' unless %w[DIRECT PROXY REJECT].include?(action) || @store.snapshot['nodes'].any? { |node| node['id'] == payload['action'] }
      raise '匹配内容不能为空' if payload['value'].to_s.strip.empty?
      rule = {
        'id' => "rule-#{SecureRandom.hex(5)}", 'name' => payload['name'].to_s.strip,
        'type' => type, 'value' => payload['value'].to_s.strip,
        'action' => action, 'enabled' => true, 'builtin' => false
      }
      rule['name'] = "#{type}: #{rule['value']}" if rule['name'].empty?
      @store.update { |data| data['rules'].unshift(rule) }
      rule
    end

    def toggle_rule(id, enabled)
      @store.update do |data|
        rule = data['rules'].find { |item| item['id'] == id }
        raise '规则不存在' unless rule
        rule['enabled'] = !!enabled
      end
      { 'id' => id, 'enabled' => !!enabled }
    end

    def remove_rule(id)
      @store.update do |data|
        rule = data['rules'].find { |item| item['id'] == id }
        raise '规则不存在' unless rule
        raise '内置规则不能删除，可将其关闭' if rule['builtin']
        data['rules'].reject! { |item| item['id'] == id }
      end
      { 'removed' => id }
    end
  end
end

if $PROGRAM_NAME == __FILE__
  resource_dir = Zhilian.utf8(File.expand_path(__dir__))
  Zhilian::App.new(resource_dir).run(open_browser: !ARGV.include?('--no-open'))
end
