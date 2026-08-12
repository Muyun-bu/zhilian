import Foundation

@main
struct EnableProxyForTest {
    static func main() {
        let store = ConfigStore()
        var config = store.load()
        config.proxyEnabled = true
        store.save(config)
        print("代理核心已设为测试启动状态")
    }
}
