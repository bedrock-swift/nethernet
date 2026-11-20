public struct HTTPServerStatus: Codable, Equatable, Sendable {
    public var name: String
    public var world: String
    public var protocolVersion: Int
    public var version: String
    public var players: Int
    public var capacity: Int
    public var gameMode: Int

    private enum CodingKeys: String, CodingKey {
        case name, version, players
        case world = "level"
        case protocolVersion = "protocol"
        case capacity = "maxPlayers"
        case gameMode = "gameType"
    }

    public init(
        name: String, world: String, protocolVersion: Int, version: String,
        players: Int, capacity: Int, gameMode: Int
    ) {
        self.name = name
        self.world = world
        self.protocolVersion = protocolVersion
        self.version = version
        self.players = players
        self.capacity = capacity
        self.gameMode = gameMode
    }
}
