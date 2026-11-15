## 1.0.1

* Windows: a listener waiting a second or more for a connection, or a socket
  waiting as long for data, could fail with a `TailcatTimeoutException`; the
  listener closed and the socket stopped reading or writing. Fixed.
* No API changes.

## 1.0.0

First release: Dart bindings for [Tailcat](https://github.com/tailscale/tailcat)
through its C library, built from upstream commit `e00cdde6ff78` (C ABI
version 1).

* `TailcatServer` and `TailcatClient`: point-to-point WireGuard tunnels over
  Tailscale's relays and NAT traversal, with no account and no control plane.
* `TailcatSocket` and `TailcatServerSocket` implement `dart:io`'s `Socket` and
  `ServerSocket`, so `HttpServer.listenOn`, `HttpClient.connectionFactory` and
  WebSockets work over a tunnel.
* `TailcatDatagramSocket` and `TailcatDatagramListener` for UDP flows.
* `TailcatKeys` for persistent identities; servers can admit only listed
  client keys (`allowedClients`, `allowClient`).
* `TailcatClient.ping` measures relay latency; `discoPing` reports whether
  the path is direct or relayed.
* Addresses and keys are redacting `TailcatSecret`s; failures are a sealed
  `TailcatException` hierarchy.
* The native library is a code asset: downloaded and verified by the build
  hook by default, or supplied or built from source through user-defines.
* macOS, Linux, Windows, Android and iOS.
