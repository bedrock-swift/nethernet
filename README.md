<div align="center">

# NetherNet

A Swift implementation of Minecraft: Bedrock Edition's WebRTC transport.

[![Swift 6.1+](https://img.shields.io/badge/Swift-6.1%2B-orange?style=flat-square&logo=swift)](https://www.swift.org)
[![NetherNet transport](https://img.shields.io/badge/transport-NetherNet-black?style=flat-square)](https://github.com/Mojang/bedrock-protocol-docs)
[![MIT license](https://img.shields.io/github/license/bedrock-swift/nethernet?style=flat-square)](LICENSE)

<a href="https://dsc.gg/bedrock-swift"><img src="https://bedrock-swift-discord.truetemm.workers.dev/discord.svg" width="320" alt="Bedrock Swift on Discord"></a>

</div>

## Getting started

Add NetherNet to your Swift package and use the `NetherNet` product. Swift 6.1 or later is required. The included WebRTC backend loads a 64-bit libdatachannel 0.24.3 shared library at runtime.

Builds with the Swift Static Linux SDK (musl) require a custom WebRTC peer backend. Statically linked applications cannot load the shared library.

```swift
.package(url: "https://github.com/bedrock-swift/nethernet.git", branch: "main")
```

### LAN echo

Run the server and client in separate terminals.

```sh
swift run nethernet-demo listen 7551 /path/to/libdatachannel
swift run nethernet-demo dial 7551 /path/to/libdatachannel
```

### HTTP signaling

Mount `NetherNetHTTPHandler` in your HTTP server to handle `GET /v1/join` and `POST /v1/join/{networkID}`. Pass the remote address as `source`. Open WebRTC connections arrive on `handler.connections`.

The default limit is eight sessions per IPv4 address or IPv6 /64, shared by players behind the same NAT. Configure `maximumConnectionsPerSource` to change it.

For Minecraft client identity, use `MinecraftKeySet.authenticatedPeer` with `HTTPJoinIdentity(authenticatePeer:)`. The connection exposes the verified token subject and key. The `verify` callback validates the offer without retaining a key. Persist the signing key for the server's SDP answers across restarts.

Cached Mojang keys continue to work during a refresh outage for up to six hours from the last successful fetch.

## Development

```sh
swift test
```

See [Contributing](.github/CONTRIBUTING.md).
