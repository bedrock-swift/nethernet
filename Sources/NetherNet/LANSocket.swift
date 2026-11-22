public struct LANAddress: Hashable, Sendable {
    public static let broadcast = LANAddress(address: .max, port: DiscoveryPacket.port)
    public let address: UInt32
    public let port: UInt16

    public init(address: UInt32, port: UInt16) {
        self.address = address
        self.port = port
    }

    public init?(_ ipv4: String, port: UInt16) {
        let parts = ipv4.split(separator: ".", omittingEmptySubsequences: false)
        let octets = parts.compactMap { UInt8($0) }
        guard parts.count == 4, octets.count == 4 else { return nil }
        self.init(address: octets.reduce(0) { ($0 << 8) | UInt32($1) }, port: port)
    }
}

#if os(Windows)
import WinSDK
private typealias SocketHandle = SOCKET
private typealias AddressLength = Int32
#elseif canImport(Darwin)
import Darwin
private typealias SocketHandle = Int32
private typealias AddressLength = socklen_t
#else
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
private typealias SocketHandle = Int32
private typealias AddressLength = socklen_t
#endif

final class LANSocket: Sendable {
    enum SocketError: Error {
        case startup(Int32)
        case create(Int32)
        case bind(LANAddress, Int32)
        case configure(Int32)
        case address(Int32)
        case receive(Int32)
        case send(Int32)
    }

    private let handle: SocketHandle
    let localAddress: LANAddress

    init(bindTo endpoint: LANAddress, receiveTimeout: UInt32 = 100) throws {
        #if os(Windows)
        var data = WSADATA()
        let startup = WSAStartup(0x0202, &data)
        guard startup == 0 else { throw SocketError.startup(startup) }
        let handle = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP.rawValue)
        let invalidHandle = SocketHandle.max
        #elseif canImport(Glibc)
        let handle = socket(AF_INET, Int32(SOCK_DGRAM.rawValue), Int32(IPPROTO_UDP))
        let invalidHandle: SocketHandle = -1
        #else
        let handle = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        let invalidHandle: SocketHandle = -1
        #endif

        guard handle != invalidHandle else {
            let error = Self.lastError
            #if os(Windows)
            _ = WSACleanup()
            #endif
            throw SocketError.create(error)
        }

        let broadcastResult: Int32
        var broadcast: Int32 = 1
        broadcastResult = withUnsafeBytes(of: &broadcast) {
            #if os(Windows)
            setsockopt(handle, SOL_SOCKET, SO_BROADCAST, $0.baseAddress?.assumingMemoryBound(to: CChar.self), Int32($0.count))
            #else
            setsockopt(handle, SOL_SOCKET, SO_BROADCAST, $0.baseAddress, socklen_t($0.count))
            #endif
        }
        guard broadcastResult == 0 else {
            let error = Self.lastError
            Self.close(handle)
            throw SocketError.configure(error)
        }
        var address = Self.socketAddress(for: endpoint)
        let size = AddressLength(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(handle, $0, size) }
        }
        guard result == 0 else {
            let error = Self.lastError
            Self.close(handle)
            throw SocketError.bind(endpoint, error)
        }
        let timeoutResult: Int32 // session timer wakeup
        #if os(Windows)
        var timeout = receiveTimeout
        timeoutResult = withUnsafeBytes(of: &timeout) {
            setsockopt(handle, SOL_SOCKET, SO_RCVTIMEO, $0.baseAddress?.assumingMemoryBound(to: CChar.self), Int32($0.count))
        }
        #else
        var timeout = timeval(tv_sec: Int(receiveTimeout / 1000), tv_usec: Int(receiveTimeout % 1000) * 1000)
        timeoutResult = withUnsafeBytes(of: &timeout) {
            setsockopt(handle, SOL_SOCKET, SO_RCVTIMEO, $0.baseAddress, socklen_t($0.count))
        }
        #endif
        guard timeoutResult == 0 else {
            let error = Self.lastError
            Self.close(handle)
            throw SocketError.configure(error)
        }
        var boundLength = size
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(handle, $0, &boundLength) }
        }
        guard bound == 0 else {
            let error = Self.lastError
            Self.close(handle)
            throw SocketError.address(error)
        }
        self.handle = handle
        localAddress = Self.endpoint(for: address)
    }

    deinit {
        Self.close(handle)
    }

    func receive(into buffer: inout [UInt8]) throws -> (bytes: [UInt8], sender: LANAddress)? {
        var address = sockaddr_in()
        var size = AddressLength(MemoryLayout<sockaddr_in>.size)
        let count = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                buffer.withUnsafeMutableBytes { bytes in
                    #if os(Windows)
                    return Int(recvfrom(
                        handle, bytes.baseAddress?.assumingMemoryBound(to: CChar.self),
                        Int32(bytes.count), 0, address, &size
                    ))
                    #else
                    return recvfrom(handle, bytes.baseAddress, bytes.count, 0, address, &size)
                    #endif
                }
            }
        }

        if count < 0 {
            let error = Self.lastError
            #if os(Windows)
            if error == WSAEINTR || error == WSAECONNRESET || error == WSAETIMEDOUT { return nil }
            #else
            if error == EINTR || error == EAGAIN || error == EWOULDBLOCK { return nil }
            #endif
            throw SocketError.receive(error)
        }

        return (Array(buffer.prefix(count)), Self.endpoint(for: address))
    }

    func send(_ datagram: [UInt8], to endpoint: LANAddress) throws {
        var address = Self.socketAddress(for: endpoint)
        let size = AddressLength(MemoryLayout<sockaddr_in>.size)
        let count = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                datagram.withUnsafeBytes { bytes in
                    #if os(Windows)
                    return Int(sendto(
                        handle, bytes.baseAddress?.assumingMemoryBound(to: CChar.self),
                        Int32(bytes.count), 0, address, size
                    ))
                    #else
                    return sendto(handle, bytes.baseAddress, bytes.count, 0, address, size)
                    #endif
                }
            }
        }
        if count < 0 {
            let error = Self.lastError
            #if os(Windows)
            if error == WSAEINTR || error == WSAECONNRESET { return }
            #else
            if error == EINTR { return }
            #endif
            throw SocketError.send(error)
        }
    }

    private static func endpoint(for address: sockaddr_in) -> LANAddress {
        LANAddress(
            address: UInt32(bigEndian: address.sin_addr.networkAddress),
            port: UInt16(bigEndian: address.sin_port)
        )
    }

    private static func socketAddress(for endpoint: LANAddress) -> sockaddr_in {
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = numericCast(AF_INET)
        address.sin_port = endpoint.port.bigEndian
        address.sin_addr.networkAddress = endpoint.address.bigEndian
        return address
    }

    private static var lastError: Int32 {
        #if os(Windows)
        WSAGetLastError()
        #else
        errno
        #endif
    }

    private static func close(_ handle: SocketHandle) {
        #if os(Windows)
        _ = closesocket(handle)
        _ = WSACleanup()
        #elseif canImport(Darwin)
        _ = Darwin.close(handle)
        #elseif canImport(Glibc)
        _ = Glibc.close(handle)
        #elseif canImport(Musl)
        _ = Musl.close(handle)
        #endif
    }
}

private extension in_addr {
    var networkAddress: UInt32 {
        get {
            #if os(Windows)
            S_un.S_addr
            #else
            s_addr
            #endif
        }
        set {
            #if os(Windows)
            S_un.S_addr = newValue
            #else
            s_addr = newValue
            #endif
        }
    }
}
