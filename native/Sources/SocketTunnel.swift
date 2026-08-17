import Foundation
import Darwin
import CryptoKit
import Security

enum TunnelError: LocalizedError {
    case connect(String), closed, protocolError(String), unsupported
    var errorDescription: String? {
        switch self { case .connect(let v): "连接失败：\(v)"; case .closed: "连接已关闭"; case .protocolError(let v): "协议错误：\(v)"; case .unsupported: "节点协议暂不支持" }
    }
}

final class SocketFD: @unchecked Sendable {
    let fd: Int32
    private let closeLock = NSLock(); private var isClosed = false
    init(fd: Int32) {
        self.fd = fd
        var enabled: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    }
    deinit { close() }

    static func connect(host: String, port: Int, timeout: Int = 10) throws -> SocketFD {
        guard !host.isEmpty, (1...65_535).contains(port) else { throw TunnelError.connect("目标地址或端口无效") }
        var hints = addrinfo(ai_flags: AI_ADDRCONFIG, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: IPPROTO_TCP,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let first = result else { throw TunnelError.connect(host) }
        defer { freeaddrinfo(result) }
        var pointer: UnsafeMutablePointer<addrinfo>? = first
        while let info = pointer?.pointee {
            let socketFD = socket(info.ai_family, info.ai_socktype, info.ai_protocol)
            if socketFD >= 0 {
                let timeoutSeconds = max(1, timeout)
                let originalFlags = fcntl(socketFD, F_GETFL, 0)
                if originalFlags >= 0 { _ = fcntl(socketFD, F_SETFL, originalFlags | O_NONBLOCK) }
                var connected = Darwin.connect(socketFD, info.ai_addr, info.ai_addrlen) == 0
                if !connected, errno == EINPROGRESS {
                    var descriptor = pollfd(fd: socketFD, events: Int16(POLLOUT), revents: 0)
                    let pollResult = Darwin.poll(&descriptor, 1, Int32(timeoutSeconds * 1_000))
                    if pollResult > 0 {
                        var socketError: Int32 = 0
                        var socketErrorLength = socklen_t(MemoryLayout<Int32>.size)
                        connected = getsockopt(socketFD, SOL_SOCKET, SO_ERROR, &socketError, &socketErrorLength) == 0
                            && socketError == 0
                    }
                }
                if connected {
                    if originalFlags >= 0 { _ = fcntl(socketFD, F_SETFL, originalFlags) }
                    var tv = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
                    setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout.size(ofValue: tv)))
                    setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout.size(ofValue: tv)))
                    return SocketFD(fd: socketFD)
                }
                Darwin.close(socketFD)
            }
            pointer = info.ai_next
        }
        throw TunnelError.connect("\(host):\(port)")
    }

    func read(max: Int = 32768) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: max)
        let count = Darwin.recv(fd, &bytes, max, 0)
        if count == 0 { return Data() }
        guard count > 0 else { throw TunnelError.closed }
        return Data(bytes.prefix(count))
    }

    func read() throws -> Data { try read(max: 32768) }

    func readExactly(_ count: Int) throws -> Data {
        var result = Data()
        while result.count < count { let chunk = try read(max: count - result.count); if chunk.isEmpty { throw TunnelError.closed }; result.append(chunk) }
        return result
    }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let count = Darwin.send(fd, base.advanced(by: sent), data.count - sent, 0)
                guard count > 0 else { throw TunnelError.closed }
                sent += count
            }
        }
    }

    func close() { closeLock.lock(); defer { closeLock.unlock() }; if !isClosed { isClosed = true; Darwin.shutdown(fd, SHUT_RDWR); Darwin.close(fd) } }
}

protocol Tunnel: AnyObject, Sendable {
    func read() throws -> Data
    func write(_ data: Data) throws
    func close()
}

extension SocketFD: Tunnel {}

final class Socks5Tunnel: Tunnel, @unchecked Sendable {
    private let socket: SocketFD

    init(proxyHost: String = "127.0.0.1", proxyPort: Int, destinationHost: String, destinationPort: Int) throws {
        guard !destinationHost.isEmpty, destinationHost.utf8.count <= 255, (1...65_535).contains(destinationPort) else {
            throw TunnelError.connect("SOCKS5 目标地址无效")
        }
        socket = try SocketFD.connect(host: proxyHost, port: proxyPort)
        try socket.write(Data([5, 1, 0]))
        let greeting = try socket.readExactly(2)
        guard greeting == Data([5, 0]) else { throw TunnelError.protocolError("SOCKS5 认证失败") }
        var request = Data([5, 1, 0, 3, UInt8(min(255, destinationHost.utf8.count))])
        request.append(contentsOf: destinationHost.utf8.prefix(255))
        var port = UInt16(destinationPort).bigEndian
        withUnsafeBytes(of: &port) { request.append(contentsOf: $0) }
        try socket.write(request)
        let response = try socket.readExactly(4)
        guard response[1] == 0 else { throw TunnelError.connect("多协议节点连接目标失败") }
        switch response[3] {
        case 1: _ = try socket.readExactly(6)
        case 3: let length = try socket.readExactly(1)[0]; _ = try socket.readExactly(Int(length) + 2)
        case 4: _ = try socket.readExactly(18)
        default: throw TunnelError.protocolError("SOCKS5 地址格式无效")
        }
    }
    func read() throws -> Data { try socket.read() }
    func write(_ data: Data) throws { try socket.write(data) }
    func close() { socket.close() }
}

final class ShadowsocksTunnel: Tunnel, @unchecked Sendable {
    private let socket: SocketFD
    private let masterKey: Data
    private var encryptKey: SymmetricKey?
    private var decryptKey: SymmetricKey?
    private var encryptNonce: UInt64 = 0
    private var decryptNonce: UInt64 = 0

    init(node: ProxyNode, destinationHost: String, destinationPort: Int) throws {
        guard node.method == "chacha20-ietf-poly1305", let password = node.password,
              !destinationHost.isEmpty, destinationHost.utf8.count <= 255,
              (1...65_535).contains(destinationPort) else { throw TunnelError.unsupported }
        socket = try SocketFD.connect(host: node.host, port: node.port)
        masterKey = Self.evpBytesToKey(password: password, length: 32)
        try write(Self.address(host: destinationHost, port: destinationPort))
    }

    func write(_ data: Data) throws {
        if encryptKey == nil {
            var salt = Data(count: 32); _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
            encryptKey = Self.derive(master: masterKey, salt: salt); try socket.write(salt)
        }
        var offset = 0
        while offset < data.count {
            let count = min(0x3fff, data.count - offset)
            var length = UInt16(count).bigEndian
            let lengthData = withUnsafeBytes(of: &length) { Data($0) }
            try socket.write(try seal(lengthData)); try socket.write(try seal(data.subdata(in: offset..<(offset + count))))
            offset += count
        }
    }

    func read() throws -> Data {
        if decryptKey == nil { let salt = try socket.readExactly(32); decryptKey = Self.derive(master: masterKey, salt: salt) }
        let encryptedLength = try socket.readExactly(18)
        let lengthData = try open(encryptedLength)
        guard lengthData.count == 2 else { throw TunnelError.protocolError("长度帧无效") }
        let length = Int(lengthData[lengthData.startIndex]) << 8 | Int(lengthData[lengthData.index(after: lengthData.startIndex)])
        return try open(socket.readExactly(length + 16))
    }

    func close() { socket.close() }

    private func seal(_ data: Data) throws -> Data {
        guard let encryptKey else { throw TunnelError.protocolError("加密密钥尚未初始化") }
        let nonce = try ChaChaPoly.Nonce(data: Self.nonce(encryptNonce)); encryptNonce += 1
        let box = try ChaChaPoly.seal(data, using: encryptKey, nonce: nonce)
        return box.ciphertext + box.tag
    }
    private func open(_ data: Data) throws -> Data {
        guard data.count >= 16 else { throw TunnelError.protocolError("数据帧过短") }
        guard let decryptKey else { throw TunnelError.protocolError("解密密钥尚未初始化") }
        let nonce = try ChaChaPoly.Nonce(data: Self.nonce(decryptNonce)); decryptNonce += 1
        let box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: data.dropLast(16), tag: data.suffix(16))
        return try ChaChaPoly.open(box, using: decryptKey)
    }
    private static func nonce(_ value: UInt64) -> Data {
        var data = Data(count: 12); var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.replaceSubrange(0..<8, with: $0) }; return data
    }
    private static func derive(master: Data, salt: Data) -> SymmetricKey {
        HKDF<Insecure.SHA1>.deriveKey(inputKeyMaterial: SymmetricKey(data: master), salt: salt, info: Data("ss-subkey".utf8), outputByteCount: 32)
    }
    private static func evpBytesToKey(password: String, length: Int) -> Data {
        let passwordData = Data(password.utf8); var result = Data(); var previous = Data()
        while result.count < length { var input = Data(); input.append(previous); input.append(passwordData); previous = Data(Insecure.MD5.hash(data: input)); result.append(previous) }
        return result.prefix(length)
    }
    private static func address(host: String, port: Int) -> Data {
        var data = Data([3, UInt8(min(255, host.utf8.count))]); data.append(contentsOf: host.utf8.prefix(255)); var p = UInt16(port).bigEndian
        withUnsafeBytes(of: &p) { data.append(contentsOf: $0) }; return data
    }
}
