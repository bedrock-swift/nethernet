import Testing
@testable import NetherNet

@Test func nativeQueueReservesCapacityForReliableEvents() async throws {
    let events = NativePeerEvents(capacity: 4, maximumBytes: 12)
    events.yield(.message(.unreliable, [1, 2, 3, 4, 5, 6]))
    events.yield(.message(.unreliable, [7]))
    events.yield(.message(.reliable, [8, 9]))
    events.finish()

    var stream = events.stream.makeAsyncIterator()
    guard case .message(.unreliable, let first)? = await stream.next(),
          case .message(.reliable, let second)? = await stream.next() else {
        Issue.record("expected one unreliable and one reliable message")
        return
    }
    #expect(first == [1, 2, 3, 4, 5, 6])
    #expect(second == [8, 9])
    #expect(await stream.next() == nil)
}

@Test func nativeQueueReportsReliableOverflowAfterQueuedEvents() async {
    let events = NativePeerEvents(capacity: 4, maximumBytes: 8)
    events.yield(.message(.reliable, [1, 2, 3, 4, 5, 6, 7]))
    events.yield(.message(.reliable, [8, 9]))
    events.yield(.open(.reliable))

    var stream = events.stream.makeAsyncIterator()
    guard case .message(.reliable, let message)? = await stream.next(),
          case .failed(let error)? = await stream.next() else {
        Issue.record("expected queued data and an overflow error")
        return
    }
    #expect(message == [1, 2, 3, 4, 5, 6, 7])
    #expect(error as? ConnectionError == .overflow)
    #expect(await stream.next() == nil)
}
