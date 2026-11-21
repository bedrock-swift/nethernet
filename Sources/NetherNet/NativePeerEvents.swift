final class NativePeerEvents: Sendable {
    private let queue: ReceiveQueue<PeerEvent>

    init(capacity: Int = 256, maximumBytes: Int = 4 * 1024 * 1024) {
        queue = ReceiveQueue(capacity: capacity, maximumBytes: maximumBytes)
    }

    var stream: AsyncStream<PeerEvent> {
        AsyncStream(unfolding: {
            do {
                return try await self.queue.next()
            } catch {
                return .failed(error)
            }
        })
    }

    func yield(_ event: PeerEvent) {
        switch event {
        case .description(_, let sdp):
            queue.offer(event, bytes: sdp.utf8.count, reliable: true)
        case .candidate(let candidate):
            queue.offer(event, bytes: candidate.utf8.count, reliable: true)
        case .message(let channel, let message):
            queue.offer(event, bytes: message.count, reliable: channel == .reliable)
        default:
            queue.offer(event, bytes: 0, reliable: true)
        }
    }

    func finish() { queue.finish() }
}
