# Contributing to NetherNet

## Issues

For bug reports, include your Swift version, operating system, what you expected, and the smallest steps that reproduce the problem. For signaling or transport bugs, include the peer implementation, its version, and whether you used LAN or HTTP. Remove tokens and private keys from traces.

## Pull requests

Keep each pull request focused. Explain what changed and how you checked it. Discuss larger protocol or public API changes in an issue first.

Build with Swift 6.1 or later and run `swift test`. To check a live transport, follow the demo commands in the README with your local libdatachannel build. Add focused tests when changing wire formats or session behavior.

Follow the surrounding Swift style. Keep necessary comments short, lowercase, and beside the relevant code. Use short, lowercase commit subjects.
