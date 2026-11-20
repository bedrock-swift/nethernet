public struct ServerData: Equatable, Sendable {
    public enum Version: UInt8, Sendable {
        case v4 = 4
        case v5
        case v6
        case v7

        fileprivate var usesVariableLengths: Bool { self == .v5 || self == .v7 }
    }

    public var name: String
    public var world: String
    public var gameMode: UInt8
    public var players: Int32
    public var capacity: Int32
    public var isEditor: Bool
    public var isHardcore: Bool
    public var transport: UInt8
    public var connectionType: UInt8
    public var protocolVersion: Int32
    public var gameVersion: String
    public var acceptsOnlineAuth: Bool
    public var acceptsSelfSignedAuth: Bool
    public var nonce: String

    public init(
        name: String, world: String, gameMode: UInt8 = 0, players: Int32 = 1, capacity: Int32 = 8,
        isEditor: Bool = false, isHardcore: Bool = false, transport: UInt8 = 2, connectionType: UInt8 = 4,
        protocolVersion: Int32 = 0, gameVersion: String = "",
        acceptsOnlineAuth: Bool = true, acceptsSelfSignedAuth: Bool = true, nonce: String = ""
    ) {
        self.name = name
        self.world = world
        self.gameMode = gameMode
        self.players = players
        self.capacity = capacity
        self.isEditor = isEditor
        self.isHardcore = isHardcore
        self.transport = transport
        self.connectionType = connectionType
        self.protocolVersion = protocolVersion
        self.gameVersion = gameVersion
        self.acceptsOnlineAuth = acceptsOnlineAuth
        self.acceptsSelfSignedAuth = acceptsSelfSignedAuth
        self.nonce = nonce
    }

    public func encode() throws -> [UInt8] {
        try encode(version: .v4)
    }

    public func encode(version: Version) throws -> [UInt8] {
        if !version.usesVariableLengths {
            guard gameMode < 128, transport < 128, connectionType < 128 else { throw WireError.malformed }
        }
        if version == .v7, transport != 2 { throw WireError.malformed } // transport is implicit in v7
        var bytes = [version.rawValue]
        try bytes.appendString(name, variableLength: version.usesVariableLengths)
        if version == .v7 {
            bytes.appendVarInt32(protocolVersion)
            try bytes.appendString(gameVersion, variableLength: true)
        }
        try bytes.appendString(world, variableLength: version.usesVariableLengths)
        if version == .v7 {
            bytes.appendVarInt32(players)
            bytes.appendVarInt32(capacity)
            bytes.appendVarInt32(Int32(gameMode))
        } else {
            if version == .v5 {
                bytes.appendVarInt32(Int32(gameMode))
            } else {
                bytes.append(gameMode << 1)
            }
            bytes.appendLE(players)
            bytes.appendLE(capacity)
        }
        bytes += [isEditor ? 1 : 0, isHardcore ? 1 : 0]
        if version != .v4 {
            bytes += [acceptsOnlineAuth ? 1 : 0, acceptsSelfSignedAuth ? 1 : 0]
        }
        if version == .v6 || version == .v7 {
            try bytes.appendString(nonce, variableLength: version.usesVariableLengths)
        }
        switch version {
        case .v4, .v6:
            bytes += [transport << 1, connectionType << 1]
        case .v5:
            bytes.appendVarInt32(Int32(transport))
            bytes.appendVarInt32(Int32(connectionType))
        case .v7:
            bytes.appendVarInt32(Int32(connectionType))
        }
        return bytes
    }

    public init(decoding bytes: [UInt8]) throws {
        var reader = WireReader(bytes)
        guard let version = Version(rawValue: try reader.integer(UInt8.self)) else { throw WireError.malformed }
        let variableLength = version.usesVariableLengths
        let name = try reader.string(variableLength: variableLength)
        let protocolVersion = try version == .v7 ? reader.varInt32() : 0
        let gameVersion = try version == .v7 ? reader.string(variableLength: true) : ""
        let world = try reader.string(variableLength: variableLength)
        let gameMode: UInt8
        let players: Int32
        let capacity: Int32
        if version == .v7 {
            players = try reader.varInt32()
            capacity = try reader.varInt32()
            gameMode = try Self.readVarUInt8(from: &reader)
        } else {
            gameMode = try version == .v5 ? Self.readVarUInt8(from: &reader) : reader.integer(UInt8.self) >> 1
            players = try reader.integer(Int32.self)
            capacity = try reader.integer(Int32.self)
        }
        let isEditor = try reader.integer(UInt8.self) != 0
        let isHardcore = try reader.integer(UInt8.self) != 0
        let acceptsOnlineAuth = try version == .v4 || reader.integer(UInt8.self) != 0
        let acceptsSelfSignedAuth = try version == .v4 || reader.integer(UInt8.self) != 0
        let nonce = try version == .v6 || version == .v7 ? reader.string(variableLength: variableLength) : ""
        let transport: UInt8
        let connectionType: UInt8
        switch version {
        case .v4, .v6:
            transport = try reader.integer(UInt8.self) >> 1
            connectionType = try reader.integer(UInt8.self) >> 1
        case .v5:
            transport = try Self.readVarUInt8(from: &reader)
            connectionType = try Self.readVarUInt8(from: &reader)
        case .v7:
            transport = 2
            connectionType = try Self.readVarUInt8(from: &reader)
        }
        guard reader.isEmpty else { throw WireError.malformed }
        self.init(
            name: name, world: world, gameMode: gameMode, players: players, capacity: capacity,
            isEditor: isEditor, isHardcore: isHardcore, transport: transport, connectionType: connectionType,
            protocolVersion: protocolVersion, gameVersion: gameVersion,
            acceptsOnlineAuth: acceptsOnlineAuth, acceptsSelfSignedAuth: acceptsSelfSignedAuth, nonce: nonce
        )
    }

    private static func readVarUInt8(from reader: inout WireReader) throws -> UInt8 {
        guard let value = UInt8(exactly: try reader.varInt32()) else { throw WireError.malformed }
        return value
    }
}
