import Foundation
#if os(Windows)
import WinSDK
#elseif canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum WebRTCError: Error, Equatable {
    case libraryUnavailable(String)
    case missingSymbol(String)
    case unsupportedArchitecture
    case native(Int32)
}

private typealias DescriptionCallback = @convention(c) (Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void
private typealias ChannelCallback = @convention(c) (Int32, Int32, UnsafeMutableRawPointer?) -> Void
private typealias OpenCallback = @convention(c) (Int32, UnsafeMutableRawPointer?) -> Void
private typealias MessageCallback = @convention(c) (Int32, UnsafePointer<CChar>?, Int32, UnsafeMutableRawPointer?) -> Void

public final class LibDataChannel: @unchecked Sendable {
    private let symbols: [String: UnsafeMutableRawPointer]

    public init(libraryPath: String) throws {
        guard MemoryLayout<Int>.size == 8 else { throw WebRTCError.unsupportedArchitecture }
        #if os(Windows)
        guard let handle = Array(libraryPath.utf16 + [0]).withUnsafeBufferPointer({ LoadLibraryW($0.baseAddress) }) else {
            throw WebRTCError.libraryUnavailable(libraryPath)
        }
        #else
        guard let handle = dlopen(libraryPath, RTLD_NOW | RTLD_LOCAL) else {
            throw WebRTCError.libraryUnavailable(libraryPath)
        }
        #endif
        let names = [
            "rtcCreatePeerConnection", "rtcDeletePeerConnection", "rtcSetUserPointer",
            "rtcSetLocalDescriptionCallback", "rtcSetLocalCandidateCallback", "rtcSetDataChannelCallback",
            "rtcSetLocalDescription", "rtcSetRemoteDescription", "rtcAddRemoteCandidate",
            "rtcCreateDataChannel", "rtcCreateDataChannelEx", "rtcDeleteDataChannel", "rtcGetDataChannelLabel",
            "rtcSetOpenCallback", "rtcSetClosedCallback", "rtcSetMessageCallback", "rtcIsOpen", "rtcSendMessage"
        ]
        var resolved: [String: UnsafeMutableRawPointer] = [:]
        for name in names {
            #if os(Windows)
            guard let symbol = GetProcAddress(handle, name) else {
                FreeLibrary(handle)
                throw WebRTCError.missingSymbol(name)
            }
            resolved[name] = unsafeBitCast(symbol, to: UnsafeMutableRawPointer.self)
            #else
            guard let symbol = dlsym(handle, name) else {
                dlclose(handle)
                throw WebRTCError.missingSymbol(name)
            }
            resolved[name] = symbol
            #endif
        }
        symbols = resolved
    }

    public func makePeer() throws -> any WebRTCPeer {
        try NativePeer(api: self)
    }

    fileprivate func function<T>(_ name: String, as type: T.Type) -> T {
        unsafeBitCast(symbols[name]!, to: type)
    }

    fileprivate func useCallbacks(for id: Int32) {
        function("rtcSetUserPointer", as: (@convention(c) (Int32, UnsafeMutableRawPointer?) -> Void).self)(
            id, UnsafeMutableRawPointer(bitPattern: 1)
        )
    }

    fileprivate func delete(_ name: String, id: Int32) {
        _ = function(name, as: (@convention(c) (Int32) -> Int32).self)(id)
    }
}

private final class CallbackRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var contexts: [Int32: ChannelContext] = [:]

    subscript(id: Int32) -> ChannelContext? {
        lock.withLock { contexts[id] }
    }

    func add(_ context: ChannelContext, for id: Int32) {
        lock.withLock { contexts[id] = context }
    }

    func remove(_ ids: [Int32]) {
        lock.withLock { for id in ids { contexts.removeValue(forKey: id) } }
    }
}

private let callbacks = CallbackRegistry()

private final class ChannelContext: @unchecked Sendable {
    let api: LibDataChannel
    let output: AsyncStream<PeerEvent>.Continuation
    private let lock = NSLock()
    private var channels: [DataChannel: Int32] = [:]
    private var channelIDs: [Int32] = []
    private var closing = false

    init(api: LibDataChannel, output: AsyncStream<PeerEvent>.Continuation) {
        self.api = api
        self.output = output
    }

    func yield(_ event: PeerEvent) {
        if case .dropped = output.yield(event) { output.finish() }
    }

    func channel(_ id: Int32) -> DataChannel? {
        lock.withLock { channels.first(where: { $0.value == id })?.key }
    }

    func id(for channel: DataChannel) -> Int32? { lock.withLock { channels[channel] } }

    func attach(_ id: Int32) {
        let label = api.function("rtcGetDataChannelLabel", as: (@convention(c) (Int32, UnsafeMutablePointer<CChar>?, Int32) -> Int32).self)
        var buffer = [CChar](repeating: 0, count: 32)
        let result = label(id, &buffer, Int32(buffer.count))
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let name = result > 0 ? DataChannel(rawValue: String(decoding: bytes, as: UTF8.self)) : nil
        let registered = lock.withLock {
            channelIDs.append(id)
            guard !closing, let name, channels[name] == nil else { return false }
            channels[name] = id
            callbacks.add(self, for: id)
            return true
        }
        guard registered else { return }
        api.useCallbacks(for: id)
        let onOpen = api.function("rtcSetOpenCallback", as: (@convention(c) (Int32, OpenCallback?) -> Int32).self)
        let onClose = api.function("rtcSetClosedCallback", as: (@convention(c) (Int32, OpenCallback?) -> Int32).self)
        let onMessage = api.function("rtcSetMessageCallback", as: (@convention(c) (Int32, MessageCallback?) -> Int32).self)
        _ = onOpen(id) { id, _ in
            guard let context = callbacks[id], let channel = context.channel(id) else { return }
            context.yield(.open(channel))
        }
        _ = onClose(id) { id, _ in callbacks[id]?.yield(.closed) }
        _ = onMessage(id) { id, data, size, _ in
            guard let data, (1...Int32(MessageCodec.maximumIncomingSegment + 1)).contains(size),
                  let context = callbacks[id], let channel = context.channel(id) else { return }
            let bytes = UnsafeRawBufferPointer(start: data, count: Int(size))
            context.yield(.message(channel, Array(bytes)))
        }
        let isOpen = api.function("rtcIsOpen", as: (@convention(c) (Int32) -> Bool).self)
        if let name, isOpen(id) { yield(.open(name)) }
    }

    func beginClose() {
        lock.withLock { closing = true }
        output.finish()
    }

    func allChannelIDs() -> [Int32] { lock.withLock { channelIDs } }
}

private final class NativePeer: WebRTCPeer, @unchecked Sendable {
    let events: AsyncStream<PeerEvent>
    private let context: ChannelContext
    private let peerID: Int32
    private let lock = NSLock()
    private var closed = false

    init(api: LibDataChannel) throws {
        let create = api.function("rtcCreatePeerConnection", as: (@convention(c) (UnsafeRawPointer) -> Int32).self)
        let config = UnsafeMutableRawPointer.allocate(byteCount: 56, alignment: 8)
        defer { config.deallocate() }
        config.initializeMemory(as: UInt8.self, repeating: 0, count: 56)
        config.storeBytes(of: UInt8(1), toByteOffset: 42, as: UInt8.self) // disable auto negotiation
        peerID = try Self.checked(create(UnsafeRawPointer(config)))

        let stream = AsyncStream<PeerEvent>.makeStream(bufferingPolicy: .bufferingOldest(256))
        events = stream.stream
        context = ChannelContext(api: api, output: stream.continuation)
        callbacks.add(context, for: peerID)
        api.useCallbacks(for: peerID)
        let onDescription = api.function("rtcSetLocalDescriptionCallback", as: (@convention(c) (Int32, DescriptionCallback?) -> Int32).self)
        let onCandidate = api.function("rtcSetLocalCandidateCallback", as: (@convention(c) (Int32, DescriptionCallback?) -> Int32).self)
        let onChannel = api.function("rtcSetDataChannelCallback", as: (@convention(c) (Int32, ChannelCallback?) -> Int32).self)
        _ = onDescription(peerID) { id, sdp, type, _ in
            guard let sdp, let type, let context = callbacks[id] else { return }
            switch String(cString: type) {
            case "offer": context.yield(.description(.offer, String(cString: sdp)))
            case "answer": context.yield(.description(.answer, String(cString: sdp)))
            default: break
            }
        }
        _ = onCandidate(peerID) { id, candidate, _, _ in
            guard let candidate else { return }
            callbacks[id]?.yield(.candidate(String(cString: candidate)))
        }
        _ = onChannel(peerID) { id, channel, _ in callbacks[id]?.attach(channel) }
    }

    deinit { close() }

    func offer() throws {
        try lock.withLock {
            guard !closed else { throw ConnectionError.closed }
            let api = context.api
            let create = api.function("rtcCreateDataChannel", as: (@convention(c) (Int32, UnsafePointer<CChar>?) -> Int32).self)
            let reliable = try Self.checked(create(peerID, DataChannel.reliable.rawValue))
            context.attach(reliable)
            let createUnordered = api.function("rtcCreateDataChannelEx", as: (@convention(c) (Int32, UnsafePointer<CChar>?, UnsafeRawPointer) -> Int32).self)
            let options = UnsafeMutableRawPointer.allocate(byteCount: 32, alignment: 8)
            defer { options.deallocate() }
            options.initializeMemory(as: UInt8.self, repeating: 0, count: 32)
            options.storeBytes(of: UInt8(1), as: UInt8.self) // unordered
            options.storeBytes(of: UInt8(1), toByteOffset: 1, as: UInt8.self) // zero retransmissions
            let unreliable = try Self.checked(createUnordered(peerID, DataChannel.unreliable.rawValue, UnsafeRawPointer(options)))
            context.attach(unreliable)
            try localDescription("offer")
        }
    }

    func remoteDescription(_ sdp: String, kind: Signal.Kind) throws {
        try lock.withLock {
            guard !closed else { throw ConnectionError.closed }
            guard !sdp.utf8.contains(0), kind == .offer || kind == .answer else { throw ConnectionError.invalidSignal }
            let set = context.api.function("rtcSetRemoteDescription", as: (@convention(c) (Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32).self)
            _ = try Self.checked(set(peerID, sdp, kind == .offer ? "offer" : "answer"))
            if kind == .offer { try localDescription("answer") }
        }
    }

    func remoteCandidate(_ candidate: String) throws {
        try lock.withLock {
            guard !closed else { throw ConnectionError.closed }
            guard !candidate.utf8.contains(0) else { throw ConnectionError.invalidSignal }
            let add = context.api.function("rtcAddRemoteCandidate", as: (@convention(c) (Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32).self)
            _ = try Self.checked(add(peerID, candidate, nil))
        }
    }

    func send(_ segments: [[UInt8]], on channel: DataChannel) throws {
        try lock.withLock {
            guard !closed, let id = context.id(for: channel) else { throw ConnectionError.notOpen }
            let send = context.api.function("rtcSendMessage", as: (@convention(c) (Int32, UnsafePointer<CChar>?, Int32) -> Int32).self)
            for segment in segments {
                guard (1...10_001).contains(segment.count) else { throw WireError.tooLarge }
                try segment.withUnsafeBytes {
                    _ = try Self.checked(send(id, $0.baseAddress?.assumingMemoryBound(to: CChar.self), Int32($0.count)))
                }
            }
        }
    }

    func close() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            context.beginClose()
            callbacks.remove([peerID])
            context.api.delete("rtcDeletePeerConnection", id: peerID)
            let channels = context.allChannelIDs()
            callbacks.remove(channels)
            for id in channels { context.api.delete("rtcDeleteDataChannel", id: id) }
        }
    }

    private func localDescription(_ type: String) throws {
        let set = context.api.function("rtcSetLocalDescription", as: (@convention(c) (Int32, UnsafePointer<CChar>?) -> Int32).self)
        _ = try Self.checked(set(peerID, type))
    }

    private static func checked(_ code: Int32) throws -> Int32 {
        guard code >= 0 else { throw WebRTCError.native(code) }
        return code
    }
}
