# libtailcat

Dart bindings for [Tailcat](https://github.com/tailscale/tailcat):
WireGuard-encrypted point-to-point TCP and UDP tunnels over Tailscale's relays
and NAT traversal. No Tailscale account, no control plane, no port forwarding,
no root.

One side starts a server and gets an address. The other side is given that
address, out of band, and connects. What you get on both ends are ordinary
`dart:io` sockets, so existing socket code, `HttpServer`, `HttpClient` and
WebSockets run over the tunnel unchanged.

Supported: macOS 13+, Linux (glibc 2.28+), Windows x64, Android (API 24+) and
iOS 13+. Not supported: the web, which has no `dart:ffi`. Needs Dart 3.10 or
Flutter 3.38.

This package is not affiliated with Tailscale. It wraps the C library that
ships in the Tailcat repository (`cmd/libtailcat`), built from a pinned
upstream commit.

## Demo

[Tin Can](example/tin_can/), the example Flutter app, on two Android phones.
They pair with a QR code and the path goes direct. Fingertips cross between
the screens in real time. Each phone leaves the app in turn, and the string
reconnects when it comes back. The Inspector shows what the library reports.

[![Play the Tin Can demo video (75 s)](https://raw.githubusercontent.com/velzosoft/libtailcat/main/video/tailcat-demo-poster.jpg)](https://github.com/user-attachments/assets/dadedf65-f09b-42de-a306-6980119803d7)

## Quick start

```yaml
dependencies:
  libtailcat: ^1.0.0
```

The listening side:

```dart
import 'package:libtailcat/libtailcat.dart';

final server = await TailcatServer.start(const TailcatServerConfig());
final listener = await server.listen(port: 8080);   // a dart:io ServerSocket

// Hand this to the other side: a QR code, a message, a config file.
// It is a secret; anyone who has it can connect.
showToUser(server.address.reveal());

await for (final socket in listener) {              // dart:io Sockets
  socket.write('hello\n');
  await socket.close();
}
```

The connecting side:

```dart
final client = TailcatClient(
  TailcatClientConfig(address: TailcatAddress(textFromTheOtherSide)),
);
final socket = await client.connect(port: 8080);
print(await utf8.decodeStream(socket));             // hello

await client.close();
```

A connection starts on a relay and moves to a direct peer-to-peer path when
NAT traversal succeeds, which it usually does. `discoPing` tells you where it
stands:

```dart
final path = await client.discoPing();
print(path.isDirect
    ? 'direct, ${path.latency.inMilliseconds} ms'
    : 'relayed via ${path.derpRegionCode}');
```

[`example/`](example/) has two complete programs: `pipe`, a two-way pipe
between terminals that also talks to the `tailcat` command-line tool, and
Tin Can, a Flutter app that keeps a private line open between two phones.

## HTTP and WebSockets

`TailcatServerSocket` is a `ServerSocket` and `TailcatSocket` is a `Socket`,
so `dart:io`'s HTTP stack takes them as they are:

```dart
// Server: any HttpServer-based framework, shelf included.
final http = HttpServer.listenOn(await server.listen(port: 80));
http.listen((request) => request.response..write('hi')..close());

// Client: every request goes to the client's server, on the port of the URL.
final http = HttpClient()..connectionFactory = client.connectionFactory;
final response = await (await http.getUrl(Uri.parse('http://tailcat/'))).close();

// WebSockets ride on the same client.
final ws = await WebSocket.connect('ws://tailcat/chat', customClient: http);
```

Use `http://` and `ws://`. The tunnel is already encrypted end to end, and a
tunnelled socket cannot be upgraded to TLS, so `https://` URLs throw
`UnsupportedError`.

## UDP

```dart
final flows = await server.listenUdp(port: 9);       // Stream<TailcatDatagramSocket>
flows.listen((flow) => flow.listen((datagram) => flow.send(datagram)));

final flow = await client.connectUdp(port: 9);
await flow.send(utf8.encode('ping'));
print(utf8.decode(await flow.first));
```

One datagram per event, at most `TailcatDatagramSocket.maxPayloadSize` (1232)
bytes each.
The server sees a flow when its first datagram arrives.

## Keys, stable addresses and allowlists

A server started without keys gets a new identity, and so a new address,
every time. Persist the keys to keep the address:

```dart
final keys = TailcatKeys.generate();     // store privateKey and presharedKey securely
final server = await TailcatServer.start(TailcatServerConfig(
  privateKey: keys.privateKey,
  presharedKey: keys.presharedKey,
));
```

By default everyone who holds the address may connect. To admit only known
clients, give each client a persistent key and list their public keys:

```dart
final client = TailcatClient(TailcatClientConfig(
  address: address,
  privateKey: clientKeys.privateKey,
));
print(client.publicKey);                 // not secret; send it to the server's owner

final server = await TailcatServer.start(TailcatServerConfig(
  allowedClients: [clientPublicKey],
));
await server.allowClient(anotherPublicKey);   // or add one later
```

## Secrets

Addresses, private keys and pre-shared keys are capabilities. `TailcatAddress`,
`TailcatPrivateKey` and `TailcatPresharedKey` wrap them so that leaking one is
an explicit act: `toString()` prints `TailcatAddress(<redacted>)`, and only
`reveal()` returns the text. Keep them out of logs, crash reports and
analytics, and store them the way you store passwords.

## Errors and timeouts

Every failure of a Tailcat operation is a `TailcatException`, which is also an
`IOException`. The hierarchy is sealed, so branch on the type and never on the
message:

| Exception | Meaning |
|---|---|
| `TailcatArgumentException` | A malformed address or key, an oversized datagram |
| `TailcatClosedException` | The resource, or the client or server that owns it, is closed |
| `TailcatTimeoutException` | The timeout elapsed; also a `TimeoutException` |
| `TailcatCancelledException` | The operation was cancelled |
| `TailcatFailureException` | The network, the relay, the peer or the library failed |

Calls that wait for the network take a `timeout`. Leaving it out means a
default of 30 seconds, never "wait forever". Reading from a socket and
accepting on a listener have no timeout; use `Stream.timeout` if you need one.

## Closing

`socket.close()` is a half-close, as in `dart:io`: it flushes and sends FIN,
and the socket is released once the peer has closed too. `socket.destroy()`
closes both directions at once.

Closing a client or a server closes everything opened through it, and their
streams end. `close()` first gives the tunnel up to five seconds to deliver
what was written; when the peer is already gone, a server uses all of them.
Pass `drain: false` to skip the wait.

## Relays

Without configuration a server uses Tailcat's public relays, which are free
and rate limited, and picks the nearest region. To use your own
[DERP relay](https://github.com/tailscale/tailscale/tree/main/cmd/derper#derp),
describe it to the server; its address then carries the relay to the clients:

```dart
final server = await TailcatServer.start(TailcatServerConfig(region: {
  'RegionID': 900,
  'RegionCode': 'mine',
  'Nodes': [
    {'Name': '900a', 'RegionID': 900, 'HostName': 'derp.example.com'},
  ],
}));
```

`derpMapUrl` points a server or a client at a different relay map instead.

## Platform setup

**Android.** Add the permission to `android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.INTERNET"/>
```

Each ABI you ship carries its own copy of the library. Build per-ABI APKs
(`flutter build apk --split-per-abi`) or an app bundle to keep downloads small.

**iOS.** A direct path to a peer on the same network counts as local network
access, so add `NSLocalNetworkUsageDescription` to `Info.plist`. iOS suspends
apps in the background, and a suspended app's tunnel stops with it.

The library calls two APIs that Apple wants declared in the app's
`PrivacyInfo.xcprivacy`, and Flutter gives a package no place to ship that
file, so declare them in your app: file timestamps
(`NSPrivacyAccessedAPICategoryFileTimestamp`, reason `C617.1`) and system boot
time (`NSPrivacyAccessedAPICategorySystemBootTime`, reason `35F9.1`).

**macOS.** A sandboxed app needs both network entitlements in its
`.entitlements` files:

```xml
<key>com.apple.security.network.client</key><true/>
<key>com.apple.security.network.server</key><true/>
```

Set the deployment target to macOS 13 or later; the Go runtime inside the
library does not run on anything older.

**Linux and Windows.** Nothing to set up.

## Build configuration

The native library is a
[code asset](https://dart.dev/tools/hooks): a build hook fetches it when you
build or run, and `dart build` and `flutter build` bundle it. By default the
hook downloads a prebuilt library from this package's GitHub releases and
verifies it against a SHA-256 that is part of the published package. The
libraries carry GitHub build-provenance attestations.

You can change where the library comes from in your app's `pubspec.yaml`:

```yaml
hooks:
  user_defines:
    libtailcat:
      # Use a library you built or audited yourself. `path` is the library
      # or a directory containing libtailcat.{so,dylib,dll}.
      native: local
      path: native/libs
```

| Key | Effect |
|---|---|
| `native: download` | The default: a verified prebuilt library |
| `native: local` with `path:` | A library you supply; no network access |
| `native: source` | Build with Go from the pinned upstream commit; needs Go and a C toolchain (Xcode, the Android NDK, or MinGW-w64 on Windows) |
| `cache_dir:` | Where downloads are kept, instead of the hook's own cache |
| `source_dir:`, `go:`, `go_toolchain:` | For `native: source`: an upstream checkout, the `go` binary, and the `GOTOOLCHAIN` to build with |
| `skip_unsupported_targets: true` | Build for a target the library does not exist for (such as Windows on Arm) without it; calls into libtailcat then fail there |

Command-line apps need `dart build cli` (or `dart run`) so that the library is
bundled; a plain `dart compile exe` does not run build hooks.

## App size

The library embeds a Go runtime and a userspace network stack. Per
architecture it adds about:

| Platform | Uncompressed | Compressed |
|---|---|---|
| Android (per ABI) | 15 to 17 MB | about 6 MB |
| iOS | 14 MB | about 5.5 MB |
| macOS | 14 to 15 MB | about 5.5 MB |
| Linux, Windows | about 15 MB | about 6 MB |

## Known limitations

- **No TLS on top.** `SecureSocket.secure(tailcatSocket)` does not work, and
  neither do `https://` URLs through `connectionFactory`. The tunnel itself is
  encrypted and authenticated end to end.
- **Tens of connections, not thousands.** Every connection that is being read
  or written keeps a helper isolate busy, two if it does both at once. Up to a
  few dozen busy connections per process is comfortable; a server for
  thousands of clients is not what this version is for.
- **Hot restart leaves servers behind.** The library cannot be unloaded, so
  servers and clients that were open when a Flutter hot restart happens stay
  up until the process ends. This only affects development.
- **One Go runtime per process.** Loading a second Go-based native library
  into the same process is not supported by Go.
- **Only the network primitives.** The `tailcat` command's SSH, file transfer
  and port-forwarding services are not part of the C library.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the development setup, the tests
and how releases are cut.

## License

BSD 3-Clause, like Tailcat itself. The prebuilt libraries contain Tailcat and
its dependencies; their notices ship with each native release as
`THIRD_PARTY_NOTICES`. WireGuard is a registered trademark of Jason A.
Donenfeld.
