<div align="center">

# NetherNet

A Swift library implementing NetherNet for Minecraft: Bedrock Edition.

[![Swift 6](https://img.shields.io/badge/Swift-6-orange?style=flat-square&logo=swift)](https://www.swift.org)
[![NetherNet transport](https://img.shields.io/badge/transport-NetherNet-black?style=flat-square)](#features)
[![MIT license](https://img.shields.io/github/license/bedrock-swift/nethernet?style=flat-square)](LICENSE)

</div>

## Features

- LAN discovery and signaling over UDP
- HTTP join client and listener with configurable identity signing and verification
- WebRTC reliable and unreliable data channels with configurable STUN and TURN servers
- Fragmentation and reassembly for reliable messages
- Protocol codecs and a WebRTC interface for custom transports

## Development

The native send buffer defaults to 4 MiB per data channel. Configure it with `LibDataChannel(libraryPath:maximumBufferedAmount:)`. A send that would exceed the limit throws `ConnectionError.sendQueueFull` before queuing any fragments. The connection remains open so the caller can retry.

Set `icePorts` on `LibDataChannel` to constrain the UDP ports used for ICE. A single-port range is intended for a single-peer test. Leave the range unset to let libdatachannel select ports automatically.

Build with Swift 6.1 or later and run `swift test`.

The echo demo uses IPv4 loopback and requires a 64-bit libdatachannel 0.24.3 shared library. Make its runtime dependencies available to the system loader, then run the server and client in separate terminals.

```sh
swift run nethernet-demo listen 7551 /path/to/libdatachannel
swift run nethernet-demo dial 7551 /path/to/libdatachannel
```

To test an HTTP join endpoint that echoes payloads, use `dial-http` with its base URL. Append a public DER key to require a signed answer.

```sh
swift run nethernet-demo dial-http https://example.com:19132 /path/to/libdatachannel
```

Mount `NetherNetHTTPHandler` in an HTTP server to serve `GET /v1/join` and `POST /v1/join/{networkID}`. Pass the request method, path and body to `handle`, then return its status, content type and body. Open WebRTC connections arrive on `handler.connections`.

Pass the HTTP peer address as `source`. Use the address from the socket or one validated by a trusted proxy. The default limit is eight sessions per IPv4 address or IPv6 /64, including verification and active connections. Players behind the same NAT share that limit. Set `maximumConnectionsPerSource` for your deployment, or pass `.unlimited` explicitly to apply only the global connection limit.

Pass `HTTPJoinIdentity` to attach a signer or require verification. The callbacks receive the canonical fingerprint payload and supply the signing keys and token trust policy.

Use `NetherNetSigningKey` for self-signed identity. Persist its PEM across restarts and pin its public DER key on clients you control.
Use `MinecraftTokenTrust` with a trusted Minecraft JWKS to verify player tokens and SDP fingerprints.
Use `MinecraftKeySet` to fetch and refresh the issuer keys over HTTPS. Pass its async verifier to `HTTPJoinIdentity`. The cache refreshes in the background after one hour and can verify tokens with cached keys during outages. After six hours since the last successful fetch, new joins require a successful refresh.
