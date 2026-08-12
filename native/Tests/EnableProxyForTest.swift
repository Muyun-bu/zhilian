import Foundation

@main
struct EnableProxyForTest {
    static func main() {
        let enabled = CommandLine.arguments.dropFirst().first != "off"
        let store = ConfigStore()
        var config = store.load()
        config.proxyEnabled = enabled
        config.systemProxyEnabled = enabled
        store.save(config)
        print(enabled ? "代理核心和系统代理已设为测试启动状态" : "测试启动状态已关闭")
    }
}
