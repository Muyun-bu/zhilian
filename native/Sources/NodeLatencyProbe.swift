import Foundation

/// Measures only the TCP connection time from this Mac to a node's entry
/// server. It deliberately does not start Mihomo or request a third-party URL.
enum NodeLatencyProbe {
    struct Measurement: Sendable {
        var milliseconds: Int?
        var error: String?
    }

    static func measure(host: String, port: Int, attempts: Int = 3, timeoutSeconds: Int = 3) -> Measurement {
        var successfulSamples: [Int] = []
        let sampleCount = max(1, attempts)
        for attempt in 0..<sampleCount {
            let started = DispatchTime.now().uptimeNanoseconds
            if let socket = try? SocketFD.connect(host: host, port: port, timeout: timeoutSeconds) {
                let elapsed = DispatchTime.now().uptimeNanoseconds - started
                socket.close()
                successfulSamples.append(max(1, Int((Double(elapsed) / 1_000_000).rounded())))
            }
            if attempt + 1 < sampleCount { Thread.sleep(forTimeInterval: 0.1) }
        }
        guard !successfulSamples.isEmpty else {
            return .init(milliseconds: nil, error: "节点服务器连接超时")
        }
        successfulSamples.sort()
        return .init(milliseconds: successfulSamples[successfulSamples.count / 2], error: nil)
    }
}
