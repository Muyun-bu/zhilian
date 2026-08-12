# 智连

智连是一款面向 Apple Silicon Mac 的原生 macOS 智能代理客户端。当前正式实现位于 [`native/`](native/)，使用 SwiftUI、Foundation 和内嵌 Mihomo 核心，提供本地 HTTP 代理、订阅管理、节点选择/测速、连接面板与国内/境外自动分流。

> 版本：0.5.2 · 最低系统：macOS 13 · 架构：Apple Silicon（arm64）

## 功能

- **订阅解析**：Clash YAML、JSON 与 Base64 URI 列表；请求时使用 ClashMeta User-Agent 获取完整节点列表。
- **协议支持**：AnyTLS、Shadowsocks、HTTP、SOCKS5、VMess、VLESS、Trojan、Hysteria2、TUIC、WireGuard（实际隧道由 Mihomo 支持）。
- **节点管理**：按地区和协议分类，选择节点，单节点测速和一键组测速。
- **智能分流**：先按域名类别识别，再按目标服务器 IP 判断中国大陆/境外；国内默认直连，境外默认经代理。
- **网络面板**：实时流量、连接历史、规则命中和出口节点。
- **本机安全**：本地 HTTP 代理、SOCKS 核心和控制接口均绑定 `127.0.0.1`。

## 构建

在 Apple Silicon Mac 上执行：

```bash
cd native
./scripts/build_native.sh
```

构建会生成以下文件到仓库上级目录的 `outputs/`：

- `智连-0.5.2.dmg`
- `智连-0.5.2-macOS.zip`

脚本会临时进行 ad-hoc 签名，适合本机测试。公开发布前请使用 Apple Developer ID 签名并完成 Apple 公证。

## 测试

基础静态检查：

```bash
xcrun swiftc -typecheck -target arm64-apple-macosx13.0 \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" native/Sources/*.swift
```

仓库提供核心模拟测试、本地 HTTP 代理烟雾测试，以及可在本机传入缓存订阅文件执行的端到端测试，位于 [`native/Tests/`](native/Tests/)。测试订阅地址、令牌、缓存文件和运行日志均不应提交。

## 仓库结构

```text
native/
  Sources/       当前原生 macOS 应用源码
  Resources/     图标、中国 IP 段、Mihomo 核心与许可证
  Tests/         单元、烟雾与端到端测试
  scripts/       图标、IP 数据与 DMG 构建脚本
app/             早期 WebView/Ruby 原型，保留作历史参考
packaging/       早期原型的打包脚本
```

## 重要说明

- 本项目默认通过 macOS HTTP/HTTPS 系统代理工作，不是 TUN/Network Extension 实现；不遵循系统代理的应用、UDP/QUIC 流量不在当前版本的接管范围内。
- 请勿提交订阅链接、令牌、`~/Library/Application Support/ZhilianNative/` 中的运行数据或任何真实配置文件。
- 内嵌 Mihomo 二进制的许可文本位于 [`native/Resources/Core/LICENSE-MIHOMO.txt`](native/Resources/Core/LICENSE-MIHOMO.txt)。
