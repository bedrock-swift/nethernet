import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum HTTPJoinError: Error, Equatable {
    case invalidEndpoint
    case invalidResponse
    case invalidAnswer
    case bodyTooLarge
    case status(Int)
    case rejected(UInt32)
    case timedOut
}

public struct NetherNetHTTPClient: Sendable {
    public let networkID: UInt64
    private let peerFactory: @Sendable () throws -> any WebRTCPeer

    public init(library: LibDataChannel, networkID: UInt64 = .random(in: 1...UInt64.max)) {
        self.init(networkID: networkID) { try library.makePeer(trickleICE: false) }
    }

    public init(
        networkID: UInt64 = .random(in: 1...UInt64.max),
        peerFactory: @escaping @Sendable () throws -> any WebRTCPeer
    ) {
        self.networkID = networkID
        self.peerFactory = peerFactory
    }

    public func connect(to endpoint: URL, timeout: Duration = .seconds(15)) async throws -> NetherNetConnection {
        guard timeout > .zero else { throw HTTPJoinError.timedOut }
        let exchange = HTTPExchange(endpoint: try Self.joinURL(endpoint, networkID: networkID))
        let connection = NetherNetConnection(
            networkID: 0, connectionID: .random(in: 1...UInt64.max), signaling: exchange, peer: try peerFactory()
        )
        await exchange.bind(connection)
        let deadline = ContinuousClock.now.advanced(by: timeout)
        do {
            try await connection.start()
            while true {
                try Task.checkCancellation()
                if try await connection.checkOpen() { return connection }
                guard ContinuousClock.now < deadline else { throw HTTPJoinError.timedOut }
                try await Task.sleep(for: .milliseconds(10))
            }
        } catch {
            await connection.close()
            throw error
        }
    }

    public func status(at endpoint: URL) async throws -> HTTPServerStatus? {
        let url = try Self.endpointURL(endpoint, path: "/v1/join")
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (status, bytes) = try await HTTPBody.load(request)
        guard (200..<300).contains(status) else { throw HTTPJoinError.status(status) }
        return bytes.isEmpty ? nil : try JSONDecoder().decode(HTTPServerStatus.self, from: bytes)
    }

    static func joinURL(_ endpoint: URL, networkID: UInt64) throws -> URL {
        try endpointURL(endpoint, path: "/v1/join/" + String(networkID))
    }

    private static func endpointURL(_ endpoint: URL, path: String) throws -> URL {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: true),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else { throw HTTPJoinError.invalidEndpoint }
        components.path = path
        guard let url = components.url else { throw HTTPJoinError.invalidEndpoint }
        return url
    }
}

private actor HTTPExchange: NetherNetSignaling {
    let endpoint: URL
    weak var connection: NetherNetConnection?

    init(endpoint: URL) { self.endpoint = endpoint }

    func bind(_ connection: NetherNetConnection) { self.connection = connection }

    func send(_ signal: Signal, to networkID: UInt64) async throws {
        guard signal.kind == .offer else { throw ConnectionError.invalidSignal }
        let body = Data(signal.data.utf8)
        guard body.count <= HTTPBody.limit else { throw HTTPJoinError.bodyTooLarge }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
        request.setValue("libhttpclient/1.0.0.0", forHTTPHeaderField: "User-Agent")
        let (status, bytes) = try await HTTPBody.load(request)
        guard (200..<300).contains(status) else { throw HTTPJoinError.status(status) }
        guard let sdp = String(data: bytes, encoding: .utf8), !sdp.isEmpty else { throw HTTPJoinError.invalidAnswer }
        let text = sdp.trimmingCharacters(in: .whitespacesAndNewlines)
        if let code = UInt32(text) { throw HTTPJoinError.rejected(code) }
        guard let connection else { throw ConnectionError.closed }
        try await connection.receive(Signal(kind: .answer, connectionID: signal.connectionID, data: sdp))
    }
}

private final class HTTPBody: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let limit = 1 << 20
    typealias Response = (Int, Data)
    let output: AsyncThrowingStream<Response, any Error>.Continuation
    private var status: Int?
    private var body = Data()

    init(output: AsyncThrowingStream<Response, any Error>.Continuation) { self.output = output }

    static func load(_ request: URLRequest) async throws -> Response {
        let stream = AsyncThrowingStream<Response, any Error>.makeStream()
        let session = URLSession(configuration: .ephemeral, delegate: HTTPBody(output: stream.continuation), delegateQueue: nil)
        let task = session.dataTask(with: request)
        defer { session.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            task.resume()
            var iterator = stream.stream.makeAsyncIterator()
            if let response = try await iterator.next() { return response }
            try Task.checkCancellation()
            throw HTTPJoinError.invalidResponse
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            output.finish(throwing: HTTPJoinError.invalidResponse)
            completionHandler(.cancel)
            return
        }
        status = response.statusCode
        guard response.expectedContentLength <= Self.limit else {
            output.finish(throwing: HTTPJoinError.bodyTooLarge)
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard data.count <= Self.limit - body.count else {
            output.finish(throwing: HTTPJoinError.bodyTooLarge)
            dataTask.cancel()
            return
        }
        body.append(data)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            output.finish(throwing: error)
            return
        }
        guard let status else {
            output.finish(throwing: HTTPJoinError.invalidResponse)
            return
        }
        output.yield((status, body))
        output.finish()
    }
}
