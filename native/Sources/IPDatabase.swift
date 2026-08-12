import Foundation
import Darwin

enum IPLocation: String { case privateNetwork, cn, overseas, unknown }

final class IPDatabase {
    private struct V4Range { let start: UInt32; let end: UInt32 }
    private struct V6Range { let start: Data; let end: Data }
    private var v4: [V4Range] = []
    private var v6: [V6Range] = []
    private var cache: [String: IPLocation] = [:]
    private let lock = NSLock()

    init(resourceURL: URL?) {
        guard let url = resourceURL, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "|")
            guard fields.count == 3 else { continue }
            if fields[0] == "4", let start = UInt32(fields[1]), let end = UInt32(fields[2]) {
                v4.append(.init(start: start, end: end))
            } else if fields[0] == "6", let start = Self.hexData(String(fields[1])), let end = Self.hexData(String(fields[2])) {
                v6.append(.init(start: start, end: end))
            }
        }
    }

    func locate(host: String) -> IPLocation {
        if Self.isPrivate(host) { return .privateNetwork }
        lock.lock(); if let hit = cache[host] { lock.unlock(); return hit }; lock.unlock()
        var hints = addrinfo(ai_flags: AI_ADDRCONFIG, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return .unknown }
        defer { freeaddrinfo(result) }
        var pointer: UnsafeMutablePointer<addrinfo>? = first
        var found: IPLocation = .overseas
        while let info = pointer?.pointee {
            if info.ai_family == AF_INET, let addr = info.ai_addr?.withMemoryRebound(to: sockaddr_in.self, capacity: 1, { $0.pointee.sin_addr }) {
                let value = UInt32(bigEndian: addr.s_addr)
                if containsV4(value) { found = .cn; break }
            } else if info.ai_family == AF_INET6, let addr = info.ai_addr?.withMemoryRebound(to: sockaddr_in6.self, capacity: 1, { $0.pointee.sin6_addr }) {
                let data = withUnsafeBytes(of: addr.__u6_addr.__u6_addr8) { Data($0) }
                if containsV6(data) { found = .cn; break }
            }
            pointer = info.ai_next
        }
        lock.lock(); cache[host] = found; lock.unlock()
        return found
    }

    private func containsV4(_ value: UInt32) -> Bool {
        var low = 0, high = v4.count - 1
        while low <= high && high >= 0 {
            let mid = (low + high) / 2, range = v4[mid]
            if value < range.start { high = mid - 1 } else if value > range.end { low = mid + 1 } else { return true }
        }
        return false
    }

    private func containsV6(_ value: Data) -> Bool {
        func compare(_ a: Data, _ b: Data) -> ComparisonResult {
            for (x, y) in zip(a, b) { if x < y { return .orderedAscending }; if x > y { return .orderedDescending } }
            return .orderedSame
        }
        var low = 0, high = v6.count - 1
        while low <= high && high >= 0 {
            let mid = (low + high) / 2, range = v6[mid]
            if compare(value, range.start) == .orderedAscending { high = mid - 1 }
            else if compare(value, range.end) == .orderedDescending { low = mid + 1 }
            else { return true }
        }
        return false
    }

    private static func hexData(_ value: String) -> Data? {
        guard value.count == 32 else { return nil }
        var data = Data(); var index = value.startIndex
        for _ in 0..<16 { let next = value.index(index, offsetBy: 2); guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }; data.append(byte); index = next }
        return data
    }

    static func isPrivate(_ host: String) -> Bool {
        let value = host.lowercased()
        if value == "localhost" || value.hasSuffix(".local") { return true }
        var address4 = in_addr()
        if inet_pton(AF_INET, value, &address4) == 1 {
            let octets = withUnsafeBytes(of: &address4.s_addr) { Array($0) }
            return octets[0] == 10 || octets[0] == 127 || (octets[0] == 169 && octets[1] == 254)
                || (octets[0] == 192 && octets[1] == 168) || (octets[0] == 172 && (16...31).contains(octets[1]))
        }
        var address6 = in6_addr()
        if inet_pton(AF_INET6, value, &address6) == 1 {
            let octets = withUnsafeBytes(of: &address6.__u6_addr.__u6_addr8) { Array($0) }
            let isLoopback = octets.dropLast().allSatisfy { $0 == 0 } && octets.last == 1
            return isLoopback || octets[0] == 0xfc || octets[0] == 0xfd || (octets[0] == 0xfe && (octets[1] & 0xc0) == 0x80)
        }
        return false
    }
}
