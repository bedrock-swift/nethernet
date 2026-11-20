<div align="center">

# NetherNet

A Swift library implementing NetherNet for Minecraft: Bedrock Edition.

[![Swift 6](https://img.shields.io/badge/Swift-6-orange?style=flat-square&logo=swift)](https://www.swift.org)
[![NetherNet transport](https://img.shields.io/badge/transport-NetherNet-black?style=flat-square)](#features)
[![MIT license](https://img.shields.io/github/license/bedrock-swift/nethernet?style=flat-square)](LICENSE)

</div>

## Features

- LAN discovery and signaling over UDP
- WebRTC reliable and unreliable data channels
- Fragmentation and reassembly for reliable messages
- Protocol codecs and a WebRTC interface for custom transports

## Development

Build with Swift 6 and run `swift test`.

The echo demo uses IPv4 loopback and requires a 64-bit libdatachannel 0.24.3 shared library. Make its runtime dependencies available to the system loader, then run the server and client in separate terminals.

```sh
swift run nethernet-demo listen 7551 /path/to/libdatachannel
swift run nethernet-demo dial 7551 /path/to/libdatachannel
```
