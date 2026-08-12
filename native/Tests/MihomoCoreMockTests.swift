import Foundation

final class MockCoreProtocol: URLProtocol {
    static var methods: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "127.0.0.1" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.methods.append(request.httpMethod ?? "GET")
        let path = request.url!.path
        let status: Int; let body: Data
        if path.hasPrefix("/proxies/") && request.httpMethod == "GET" {
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
        precondition(delay == 42)
        precondition(MockCoreProtocol.methods.contains("PUT"))
        print("PASS: 核心就绪检查、节点切换、提供器节点特殊名称编码和测速解析")
    }
}
