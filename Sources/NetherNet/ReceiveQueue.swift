import Foundation

final class ReceiveQueue<Element: Sendable>: @unchecked Sendable {
    enum Admission {
        case enqueued
        case discarded
        case overflow
        case closed
    }

    private let lock = NSLock()
    private let ready: AsyncStream<Void>
    private let notify: AsyncStream<Void>.Continuation
    private let maximumBytes: Int
    private var queue: [(value: Element, bytes: Int)?]
    private var head = 0
    private var count = 0
    private var bytes = 0
    private var finished = false
    private var failure: (any Error)?

    init(capacity: Int, maximumBytes: Int = 4 * 1024 * 1024) {
        precondition(capacity > 0 && maximumBytes > 0)
        queue = Array(repeating: nil, count: capacity)
        self.maximumBytes = maximumBytes
        let signal = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        ready = signal.stream
        notify = signal.continuation
    }

    @discardableResult func offer(_ value: Element, bytes size: Int, reliable: Bool) -> Admission {
        let admission: Admission = lock.withLock {
            guard !finished else { return .closed }
            if !reliable, count >= queue.count / 2 || size > maximumBytes / 2 - bytes {
                return .discarded
            }
            guard count < queue.count, size <= maximumBytes - bytes else {
                finished = true
                failure = ConnectionError.overflow
                return .overflow
            }
            queue[(head + count) % queue.count] = (value, size)
            count += 1
            bytes += size
            return .enqueued
        }
        if admission == .enqueued || admission == .overflow { notify.yield(()) }
        return admission
    }

    func finish(throwing error: (any Error)? = nil) {
        lock.withLock {
            guard !finished else { return }
            finished = true
            failure = error
        }
        notify.finish()
    }

    func next() async throws -> Element? {
        var wake = ready.makeAsyncIterator()
        var wakeFinished = false
        while !Task.isCancelled {
            let result: (value: Element?, finished: Bool) = try lock.withLock {
                if let entry = queue[head] {
                    queue[head] = nil
                    head = (head + 1) % queue.count
                    count -= 1
                    bytes -= entry.bytes
                    return (entry.value, false)
                }
                if let failure {
                    self.failure = nil
                    throw failure
                }
                return (nil, finished)
            }
            if let value = result.value { return value }
            if result.finished || wakeFinished { return nil }
            wakeFinished = await wake.next() == nil
        }
        return nil
    }
}
