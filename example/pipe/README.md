# pipe

A two-way pipe between two machines: what you type on one side comes out on
the other. There is no account, no port forwarding, and nothing in between
that can read the traffic. It is the smallest complete libtailcat program,
and the whole of it is [`bin/pipe.dart`](bin/pipe.dart).

## Run it

You need the Dart SDK (3.10 or later). On both machines:

```sh
cd example/pipe
dart pub get
```

On the first machine, listen. It prints an address:

```sh
dart run bin/pipe.dart
```

On the second machine, connect with that address:

```sh
dart run bin/pipe.dart <address>
```

Type on either side and press Enter; the line appears on the other side.
Ctrl-D on either side ends the session, and both programs exit. Pipes work
too:

```sh
dart run bin/pipe.dart <address> < notes.txt
```

The address is a secret: anyone who has it can connect while the listener
runs. A new one is made every time you start listening.

The connecting side reports the path the tunnel took. It starts on one of
Tailcat's public relays and usually moves to a direct, peer-to-peer path
within a second or two.

## With the tailcat command-line tool

`pipe` uses port 1, the port [`tailcat`](https://github.com/tailscale/tailcat)
uses for its own pipe, so the two talk to each other:

```sh
# pipe listens, tailcat connects: text flows both ways
dart run bin/pipe.dart
tailcat <address>

# tailcat listens, pipe connects
tailcat
dart run bin/pipe.dart <address>
```

`tailcat` with no arguments only receives: it writes what arrives to its
standard output and sends nothing back.

To install `tailcat`, see upstream's
[INSTALL.md](https://github.com/tailscale/tailcat/blob/main/INSTALL.md); with
Go it is `go install github.com/tailscale/tailcat/cmd/tailcat@latest`.

## Build a standalone binary

```sh
dart build cli
build/cli/macos_arm64/bundle/bin/pipe      # the folder names your OS and CPU
```

The bundle holds the executable in `bin/` and the native library in `lib/`;
copy the whole `bundle` folder, not only the executable.

A plain `dart compile exe` does not work here. It does not run build hooks,
so the native library would be missing.

## Where the native library comes from

libtailcat's build hook supplies the native library. Without configuration it
downloads a prebuilt, checksummed library. `pubspec.yaml` shows where the
hook's settings go; the README of libtailcat lists them under "Build
configuration".
