import Foundation

final class MockCoreProtocol: URLProtocol {
    // URLProtocol callbacks are serialized by this test's ephemeral session.
    // Mark the test-only recorder explicitly so Swift 6 does not infer an
    // application-level shared-state contract from the fixture.
    nonisolated(unsafe) static var methods: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "127.0.0.1" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.methods.append(request.httpMethod ?? "GET")
        let path = request.url!.path
        let status: Int; let body: Data
        if path == "/connections" {
            status = 200; body = Data("""
            {"uploadTotal":1234,"downloadTotal":5678,"memory":4096,"connections":[{"id":"11111111-2222-3333-4444-555555555555","upload":120,"download":340,"start":"2026-08-13T02:43:10.396758+08:00","chains":["香港 01/AnyTLS","智连节点"],"rule":"Match","rulePayload":"","metadata":{"network":"tcp","type":"HTTPS","destinationPort":"443","host":"example.com"}},{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","upload":12,"download":34,"start":"2026-08-13T02:43:11+08:00","chains":["DIRECT"],"rule":"RuleSet","rulePayload":"zhilian-cn-ip","metadata":{"network":"tcp","type":"HTTP","destinationIP":"114.114.114.114","destinationPort":53}}]}
            """.utf8)
        } else if path.hasPrefix("/proxies/") && request.httpMethod == "GET" {
            status = 200; body = Data("{\"type\":\"Selector\",\"all\":[\"香港 01/AnyTLS\"]}".utf8)
        } else if request.httpMethod == "PUT" {
            status = 204; body = Data()
        } else if path.contains("/providers/proxies/zhilian-subscription/") && path.contains("/healthcheck") {
            status = 200; body = Data("{\"delay\":42}".utf8)
        } else { status = 404; body = Data() }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct MihomoCoreMockTests {
    static func main() async throws {
        let core = MihomoCore(protocolClasses: [MockCoreProtocol.self])
        try await core.select(node: "香港 01/AnyTLS")
        let delay = try await core.latency(node: "香港 01/AnyTLS")
        let snapshot = try await core.connectionSnapshot()
        precondition(delay == 42)
        precondition(snapshot.uploadTotal == 1234 && snapshot.downloadTotal == 5678)
        precondition(snapshot.connections.first?.host == "example.com")
        precondition(snapshot.connections.first?.uploaded == 120)
        precondition(snapshot.connections.contains { $0.host == "114.114.114.114" && $0.action == .direct && $0.node == nil })
        precondition(MockCoreProtocol.methods.contains("PUT"))
        print("PASS: 核心就绪检查、节点切换、提供器节点特殊名称编码和测速解析")
    }
}
