public struct Signal: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case offer = "CONNECTREQUEST"
        case answer = "CONNECTRESPONSE"
        case candidate = "CANDIDATEADD"
        case error = "CONNECTERROR"
    }

    public let kind: Kind
    public let connectionID: UInt64
    public let data: String

    public init(kind: Kind, connectionID: UInt64, data: String) {
        self.kind = kind
        self.connectionID = connectionID
        self.data = data
    }

    public init(parsing text: String) throws {
        let fields = text.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count == 3, let kind = Kind(rawValue: String(fields[0])),
              !fields[1].isEmpty, fields[1].utf8.allSatisfy({ (48...57).contains($0) }),
              let id = UInt64(fields[1]) else { throw WireError.malformed }
        self.init(kind: kind, connectionID: id, data: String(fields[2]))
    }

    public var text: String { "\(kind.rawValue) \(connectionID) \(data)" }
}

public protocol NetherNetSignaling: Sendable {
    func send(_ signal: Signal, to networkID: UInt64) async throws
}
