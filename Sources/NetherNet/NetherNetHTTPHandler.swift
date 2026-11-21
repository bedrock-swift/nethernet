import Foundation

public struct HTTPJoinResponse: Sendable {
    public let statusCode: Int
    public let contentType: String?
    public let body: Data

    fileprivate init(_ statusCode: Int, contentType: String? = nil, body: Data = Data()) {
        self.statusCode = statusCode
        self.contentType = contentType
        self.body = body
    }
}

public actor NetherNetHTTPHandler {
    public nonisolated let connections: AsyncStream<NetherNetConnection>

    private let listener: NetherNetHTTPListener
    private var status: HTTPServerStatus?
    private var closed = false

    public init(listener: NetherNetHTTPListener, status: HTTPServerStatus? = nil) {
        self.listener = listener
        self.status = status
        connections = listener.connections
    }

    public func setStatus(_ status: HTTPServerStatus?) { self.status = status }

    public func close() async {
        closed = true
        await listener.close()
    }

    public func handle(method: String, path: String, body: Data = Data()) async -> HTTPJoinResponse {
        guard !closed else { return HTTPJoinResponse(503) }
        let path = path.prefix { $0 != "?" }
        if path == "/v1/join" {
            guard method == "GET" else { return HTTPJoinResponse(405) }
            guard let status else { return HTTPJoinResponse(200) }
            guard let data = try? JSONEncoder().encode(status) else { return HTTPJoinResponse(500) }
            return HTTPJoinResponse(200, contentType: "application/json", body: data)
        }

        let prefix = "/v1/join/"
        guard path.hasPrefix(prefix) else { return HTTPJoinResponse(404) }
        guard method == "POST" else { return HTTPJoinResponse(405) }
        let identifier = path.dropFirst(prefix.count)
        guard !identifier.isEmpty, identifier.utf8.allSatisfy({ (48...57).contains($0) }),
              let networkID = UInt64(identifier) else { return HTTPJoinResponse(400) }
        guard body.count <= maximumHTTPJoinBody else { return HTTPJoinResponse(413) }
        guard !body.isEmpty, let offer = String(data: body, encoding: .utf8) else { return HTTPJoinResponse(400) }

        do {
            let answer = try await listener.answer(offer, from: networkID)
            return HTTPJoinResponse(200, contentType: "application/sdp", body: Data(answer.utf8))
        } catch HTTPJoinError.tooManyConnections, ConnectionError.closed, MinecraftKeySetError.unavailable, is CancellationError {
            return HTTPJoinResponse(503)
        } catch HTTPJoinError.timedOut {
            return HTTPJoinResponse(504)
        } catch is SDPIdentityError, is NetherNetIdentityError, is ES384JWS.FormatError, is DecodingError {
            return HTTPJoinResponse(403)
        } catch {
            return HTTPJoinResponse(500)
        }
    }
}
