# Contributing

## Development

```sh
dart pub get
dart test test/unit                      # pure Dart; needs neither Go nor a native library
echo '{"native": "source"}' > hook/local_config.json
dart test                                # everything hermetic; needs Go and a C compiler
dart test --run-skipped -t network       # the public relays; run sparingly
(cd tool/ffigen && dart pub get && dart run bin/generate.dart)   # regenerate the FFI bindings
dart run tool/build_native.dart --os macos --arch arm64 --out build/native
dart run tool/smoke_test.dart --platform android                 # or ios; see below
```

The native library is built by the hook in `hook/build.dart`. Build hooks run
with a filtered environment, so environment variables cannot configure them.
While working on this package, the git-ignored `hook/local_config.json` takes
the same keys as the pubspec user-defines and overrides them. It is only read
because this package's own `pubspec.yaml` names it through the `local_config`
user-define; applications never inherit it. Useful contents:

```json
{"native": "source", "go_toolchain": "local", "source_dir": "../../tailcat"}
```

`native: source` fetches the upstream commit pinned in `native/UPSTREAM` and
builds it with exactly the Go version upstream uses, downloading that
toolchain on first use. `go_toolchain: local` builds with the Go you have
instead, and `source_dir` builds a checkout of your own.

The package's own `pubspec.yaml` also sets `allow_missing_native: true`, so
`dart test test/unit` runs where the library can be neither built nor
downloaded. Tests that need it skip themselves and say why.

pub.dev accepts only `hook/build.dart` and `hook/link.dart` under `hook/`. The
hook's helpers therefore live in `lib/src/hook/`.

## Tests

| Where | What | Needs |
|---|---|---|
| `test/unit/` | Models, redaction, error mapping, the handle tree, the helper-isolate plumbing, the build hook | Nothing |
| `test/native/` (tag `native`) | The library end to end against a DERP relay on 127.0.0.1 (`tool/testrelay`): TCP, UDP, timeouts, cancellation, close trees, backpressure, HTTP and WebSockets, VM shutdown | Go |
| `test/interop/` (tag `interop`) | Dart against upstream's `tailcat` command-line tool, both ways | Go |
| `test/native/public_relay_test.dart` (tag `network`) | The default path over the public relays; skipped unless asked for | Go, network |
| `tool/smoke_app` | The library inside an app sandbox on Android and iOS; not in CI | Flutter, an emulator or simulator |
| `example/tin_can/test/unit` | Tin Can's codecs, audio, telemetry, and its host, guest and pairing over an in-memory network | Flutter |
| `example/tin_can/test/native` | Tin Can's host and guest over real tunnels on the local relay; not in CI | Flutter, Go |
| `example/tin_can/integration_test` | The app in its sandbox, driven through the UI, over the public relays; not in CI | Flutter, a desktop or simulator |

The relay and the command-line tool are compiled from the pinned upstream
checkout, the relay through `go build -overlay` so that it needs no module of
its own.

### The smoke app

Android denies an app the list of network interfaces, resolves names and
finds TLS roots differently from a desktop process, and iOS loads the library
from a framework. None of that shows in `dart test`, so
`tool/smoke_test.dart` runs `tool/smoke_app` on a device and reads the verdict
from the device log:

```sh
# Boot the emulator cold with explicit DNS servers: a stale snapshot can leave
# name resolution broken in a way that looks like a library bug.
emulator -avd <name> -no-snapshot -dns-server 8.8.8.8,1.1.1.1
dart run tool/smoke_test.dart --platform android
dart run tool/smoke_test.dart --platform ios            # a booted simulator
dart run tool/smoke_test.dart --platform android --hot-restart
```

Run it on both platforms after every change to `native/`. `--hot-restart`
checks that a Flutter hot restart gets past helper isolates that are waiting
inside native calls.

### The examples

`example/pipe` (Dart) and `example/tin_can` (Flutter) are packages of their
own with a `path: ../..` dependency on libtailcat; the root analysis excludes
them, and the `examples` CI job runs their analysis and unit tests. Both
pubspecs name `../../hook/local_config.json` as their `local_config`, so the
same override file configures the package's tests and both examples. In a
copy from pub.dev that file does not exist and the default download applies.

```sh
(cd example/pipe && dart pub get && dart analyze --fatal-infos)
(cd example/tin_can && flutter pub get && flutter analyze && flutter test test/unit)
(cd example/tin_can && flutter test test/native)    # with {"native": "source"}
```

When running Tin Can on two devices, use hot reload, not hot restart: a hot
restart leaves the old server running with the same key next to the new one.

## How the runtime works

Every network call of the C library blocks, and the VM cannot kill an isolate
that is inside an FFI call. Two rules follow, and most of `lib/src/runtime/`
exists to keep them:

1. **Blocking calls run on helper isolates.** One-shot calls (`blocking.dart`)
   use a short-lived isolate each. The three loops, accepting (`acceptor.dart`),
   reading (`reader.dart`) and writing (`writer.dart`), each have a long-lived
   one (`worker.dart`).
2. **No helper waits in native code without a bound.** One-shot calls carry a
   token with a finite deadline. Loops wait in one-second slices
   (`token.dart`) and check in between whether their owner still wants them.
   Without this a Flutter hot restart or a VM shutdown hangs;
   `test/native/shutdown_test.dart` guards it.

`handle.dart` mirrors the library's resource tree, so that closing a client or
a server ends the streams of everything under it. `lib/src/io/` puts the
`dart:io` interfaces on top.

## Moving to a new upstream commit

```sh
dart run tool/sync_upstream.dart <full commit hash>
```

This rewrites `native/UPSTREAM` and refreshes the files under `native/` that
are copies of upstream's. Then:

1. Review `git diff native/`. If `tailcat.h` changed, regenerate the bindings
   and adjust `lib/src/bindings/native_api.dart`.
2. Run `dart test` with `"native": "source"`, then the smoke app on Android
   and iOS.
3. Check whether `native/patches/android_ifaces.go` is still needed: build
   without it and see whether the Android smoke test still fails. Remove the
   patch as soon as it does not.
4. Cut a native release.

## Cutting a native release

A new native release is needed when the shared library would change: a new
upstream commit, a change to `native/patches/` or `native/build-tags.txt`, or
a change to the build plan in `lib/src/hook/go_build.dart`. Pure Dart changes
reuse the pinned release.

1. Start the **Native release** workflow from the Actions tab with a build
   number: 1 for the first release of an upstream commit, 2 for the next one
   of the same commit, and so on. The tag is `native-<commit>-<n>`.
2. The workflow builds the libraries in `NativeTarget.releaseTargets`,
   publishes them with `SHA256SUMS`, `BUILD_INFO.json` and
   `THIRD_PARTY_NOTICES` as a GitHub release, attests their provenance,
   downloads every asset back to verify it, and pushes a
   `native-manifest/<tag>` branch that pins the digests. Opening a pull
   request for that branch needs "Allow GitHub Actions to create and approve
   pull requests" in the repository's Actions settings; without it, open the
   pull request by hand or pin the checksums locally:

   ```sh
   gh release download <tag> --pattern SHA256SUMS
   dart run tool/update_manifest.dart --sums SHA256SUMS --tag <tag>
   ```

3. Merge the manifest change, run the smoke app once with the downloaded
   libraries (`dart run tool/smoke_test.dart --platform android --native download`),
   then publish a package version. Applications only receive new libraries
   through a new package version.

Never delete a `native-*` release: every published package version downloads
from the release it pinned.

## Publishing

Bump `version:` in `pubspec.yaml`, update `CHANGELOG.md`, commit, and push a
`vX.Y.Z` tag. `.github/workflows/publish.yml` checks that the tag matches the
pubspec version and that a native release is pinned, skips versions that are
already on pub.dev, and otherwise publishes through pub.dev's automated
publishing from the protected `pub.dev` environment.

## Repository layout

| Path | Contents |
|---|---|
| `lib/libtailcat.dart` | The public API. |
| `lib/src/` | `client.dart`, `server.dart` and the model types; `io/` (sockets and listeners); `runtime/` (helper isolates, tokens, the handle tree, errors); `bindings/` (generated bindings and the typed wrapper around them); `hook/` (the build hook's logic). |
| `hook/build.dart` | The build hook's entry point. |
| `native/` | `UPSTREAM` (the pinned commit), copies of upstream's header, build tags and license, and `patches/`. |
| `tool/` | `build_native.dart`, `update_manifest.dart`, `sync_upstream.dart`, `smoke_test.dart`, `testrelay/` (Go), `smoke_app/` (Flutter), `ffigen/`, `ci/`. |
| `test/` | See above. |
| `example/` | `README.md` (the index, and pub.dev's Example tab), `pipe/` (Dart) and `tin_can/` (Flutter), each a package of its own. |
| `specs/` | Design notes (empty for now). |
