# libtailcat examples

libtailcat connects two programs through a WireGuard tunnel over Tailscale's
relays and NAT traversal. One side starts a server and gets an address; the
other side is given that address and connects. There is no account, no port
forwarding and no server of your own, and both ends get ordinary `dart:io`
sockets, so `HttpServer`, `HttpClient` and WebSockets work over the tunnel
unchanged.

| Example | What it is | Run it |
|---------|------------|--------|
| [`pipe/`](pipe/) | A two-way pipe between two terminals, about 100 lines. It also talks to the `tailcat` command-line tool. | `cd pipe && dart run bin/pipe.dart`, then `dart run bin/pipe.dart <address>` on the other machine |
| [`tin_can/`](tin_can/) | A Flutter app for Android, iOS and macOS: a private line between two devices. Pair once with a QR code, then see each other's fingertip, pluck the string, and talk while holding a button. Every value the library reports is on screen. | `cd tin_can && flutter run` on two devices |

Each example is a package of its own that depends on libtailcat by path, and
its `pubspec.yaml` shows where an application configures libtailcat's build
hook.

## The core of it

Both sides of `pipe`, cut down to the calls that matter:

```dart
import 'dart:io';

import 'package:libtailcat/libtailcat.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.isEmpty) {
    // Listen. The address is a secret: whoever has it can connect.
    final server = await TailcatServer.start(const TailcatServerConfig());
    final listener = await server.listen(port: 1); // a dart:io ServerSocket
    stderr.writeln('Connect with: ${server.address.reveal()}');
    final socket = await listener.first; // a dart:io Socket
    await stdout.addStream(socket);
    await server.close();
  } else {
    // Connect. The address is all the client needs.
    final client = TailcatClient(
      TailcatClientConfig(address: TailcatAddress(arguments.single)),
    );
    final socket = await client.connect(port: 1);
    await socket.addStream(stdin);
    await socket.close(); // the other side sees the end of the stream
    await client.close(); // waits until the last bytes are delivered
  }
}
```

The tunnel starts on a relay and usually moves to a direct path within a
second or two; `client.discoPing()` reports which. See the
[package README](https://pub.dev/packages/libtailcat) for UDP, persistent
keys, allowlists and the build configuration.
