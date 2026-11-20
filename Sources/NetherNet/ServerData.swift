public struct ServerData: Equatable, Sendable {
    public var name: String
    public var world: String
    public var gameMode: UInt8
    public var players: Int32
    public var capacity: Int32
    public var isEditor: Bool
    public var isHardcore: Bool
    public var transport: UInt8
    public var connectionType: UInt8

    public init(
        name: String, world: String, gameMode: UInt8 = 0, players: Int32 = 1, capacity: Int32 = 8,
        isEditor: Bool = false, isHardcore: Bool = false, transport: UInt8 = 2, connectionType: UInt8 = 4
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
    }

    public func encode() throws -> [UInt8] {
        guard gameMode < 128, transport < 128, connectionType < 128 else { throw WireError.malformed }
        var bytes: [UInt8] = [4]
        try bytes.appendString(name)
        try bytes.appendString(world)
        bytes.append(gameMode << 1)
        bytes.appendLE(players)
        bytes.appendLE(capacity)
        bytes += [isEditor ? 1 : 0, isHardcore ? 1 : 0, transport << 1, connectionType << 1]
        return bytes
    }

    public init(decoding bytes: [UInt8]) throws {
        var reader = WireReader(bytes)
        guard try reader.integer(UInt8.self) == 4 else { throw WireError.malformed }
        self.init(
            name: try reader.string(), world: try reader.string(), gameMode: try reader.integer(UInt8.self) >> 1,
            players: try reader.integer(Int32.self), capacity: try reader.integer(Int32.self),
            isEditor: try reader.integer(UInt8.self) != 0, isHardcore: try reader.integer(UInt8.self) != 0,
            transport: try reader.integer(UInt8.self) >> 1, connectionType: try reader.integer(UInt8.self) >> 1
        )
        guard reader.isEmpty else { throw WireError.malformed }
    }
}
