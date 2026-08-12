import Foundation

@main
struct ProxyServerSmokeTests {
    static func main() throws {
        let database = IPDatabase(resourceURL: URL(fileURLWithPath: "zhilian/native/Resources/china-ip-ranges.txt"))
        let server = ProxyServer(router: RoutingEngine(database: database))
        try server.start(port: 27999)
        print("PASS: 本地 HTTP 代理监听 127.0.0.1:27999")
        server.stop()
    }
}
