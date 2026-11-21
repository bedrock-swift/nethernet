import Foundation

final class NativePeerEvents: @unchecked Sendable {
    private let lock = NSLock()
    private let ready: AsyncStream<Void>
    private let notify: AsyncStream<Void>.Continuation
    private let maximumBytes: Int
    private var queue: [(event: PeerEvent, bytes: Int)?]
    private var head = 0
    private var count = 0
    private var bytes = 0
    private var finished = false
    private var overflowed = false

    init(capacity: Int = 256, maximumBytes: Int = 4 * 1024 * 1024) {
        queue = Array(repeating: nil, count: capacity)
        self.maximumBytes = maximumBytes
        let signal = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        ready = signal.stream
        notify = signal.continuation
    }

    var stream: AsyncStream<PeerEvent> { AsyncStream(unfolding: next) }

    func yield(_ event: PeerEvent) {
        let size: Int
        switch event {
        case .description(_, let sdp): size = sdp.utf8.count
        case .candidate(let candidate): size = candidate.utf8.count
        case .message(_, let message): size = message.count
        default: size = 0
        }
        let wake = lock.withLock {
            guard !finished else { return false }
            if case .message(.unreliable, _) = event,
               count >= queue.count / 2 || size > maximumBytes / 2 - bytes { return false } // reserve space for reliable events
            guard count < queue.count, size <= maximumBytes - bytes else {
                finished = true
                overflowed = true
                return true
            }
            queue[(head + count) % queue.count] = (event, size)
            count += 1
            bytes += size
            return true
        }
        if wake { notify.yield(()) }
    }

    func finish() {
        lock.withLock { finished = true }
        notify.finish()
    }

    private func next() async -> PeerEvent? {
        var wake = ready.makeAsyncIterator()
        while !Task.isCancelled {
            let result: (event: PeerEvent?, finished: Bool) = lock.withLock {
                if let entry = queue[head] {
                    queue[head] = nil
                    head = (head + 1) % queue.count
                    count -= 1
                    bytes -= entry.bytes
                    return (entry.event, false)
                }
                if overflowed {
                    overflowed = false
                    return (.failed(ConnectionError.overflow), false)
                }
                return (nil, finished)
            }
            if let event = result.event { return event }
            if result.finished || Task.isCancelled { return nil }
            if await wake.next() == nil { return nil }
        }
        return nil
    }
}
