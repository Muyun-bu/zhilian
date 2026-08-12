import Foundation

@main
struct ProxyServerSmokeTests {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let resource = [root.appendingPathComponent("native/Resources/china-ip-ranges.txt"),
                        root.appendingPathComponent("zhilian/native/Resources/china-ip-ranges.txt")]
            .first { FileManager.default.fileExists(atPath: $0.path) }
        precondition(resource != nil, "找不到中国 IP 数据库测试资源")
        let database = IPDatabase(resourceURL: resource)
        let server = ProxyServer(router: RoutingEngine(database: database))
        do {
            try server.start(port: -1)
            preconditionFailure("无效端口不应启动")
        } catch {}
        try server.start(port: 27999)
        print("PASS: 本地 HTTP 代理监听 127.0.0.1:27999")
        server.stop()
    }
}
