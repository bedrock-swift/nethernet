import NetherNet

enum DemoError: Error {
    case usage
    case timeout
    case mismatch
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 3, let port = UInt16(arguments[1]), port != 0 else {
    print("usage: nethernet-demo listen|dial port /path/to/libdatachannel")
    throw DemoError.usage
}
let api = try LibDataChannel(libraryPath: arguments[2])
let loopback: UInt32 = 0x7f000001

switch arguments[0] {
case "listen":
    let data = try ServerData(name: "NetherNet", world: "Echo").encode()
    let listener = try NetherNetLAN(on: LANAddress(address: loopback, port: port), advertisement: data) {
        try api.makePeer()
    }
    await listener.start()
    print("listening on 127.0.0.1:\(port)")
    for await connection in listener.connections {
        Task {
            do {
                for try await payload in connection.messages { try await connection.send(payload) }
            } catch {
                await connection.close()
            }
        }
    }
case "dial":
    let client = try NetherNetLAN(on: LANAddress(address: loopback, port: 0)) { try api.makePeer() }
    try await client.discover(at: LANAddress(address: loopback, port: port))
    let server = try await withThrowingTaskGroup(of: LANAdvertisement.self) { group in
        group.addTask {
            for await advertisement in client.advertisements { return advertisement }
            throw DemoError.timeout
        }
        group.addTask {
            try await Task.sleep(for: .seconds(5))
            throw DemoError.timeout
        }
        defer { group.cancelAll() }
        guard let advertisement = try await group.next() else { throw DemoError.timeout }
        return advertisement
    }
    let connection = try await client.connect(to: server.networkID)
    let payload = (0..<20_100).map { UInt8(truncatingIfNeeded: $0) }
    try await connection.send(payload)
    let reply = try await withThrowingTaskGroup(of: [UInt8].self) { group in
        group.addTask {
            for try await message in connection.messages { return message }
            throw DemoError.timeout
        }
        group.addTask {
            try await Task.sleep(for: .seconds(5))
            throw DemoError.timeout
        }
        defer { group.cancelAll() }
        guard let message = try await group.next() else { throw DemoError.timeout }
        return message
    }
    guard reply == payload else { throw DemoError.mismatch }
    print("Received \(reply.count) echoed bytes")
    await client.close()
default:
    throw DemoError.usage
}
