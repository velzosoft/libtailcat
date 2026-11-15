// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

// One-shot blocking C calls, each on a helper isolate with a finite deadline:
// the VM can't kill an isolate inside an FFI call.
//
// Closures for [Isolate.run] are built in top-level functions that capture
// only ints and strings; one capturing a method's context could hold
// something unsendable and fail at run time.

import 'dart:async';
import 'dart:isolate';

import '../bindings/native_api.dart' as native;
import 'errors.dart';

/// Deadline of a one-shot call when the caller passes no timeout.
const defaultTimeout = Duration(seconds: 30);

/// How long closing a client or server waits for its TCP stack to drain.
const defaultDrainTimeout = Duration(seconds: 5);

/// A one-shot native call in flight on a helper isolate.
final class BlockingCall<R> {
  BlockingCall._(this.result, this._token);

  /// Completes with the result of the call, or with a [TailcatException].
  final Future<R> result;

  int _token;

  /// Interrupts the call; [result] then fails with
  /// [TailcatCancelledException] unless completion wins the race.
  void cancel() => native.cancelToken(_token);
}

BlockingCall<R> _start<R>(Duration timeout, R Function(int token) call) {
  final token = native.newToken(timeout);
  late final BlockingCall<R> running;
  Future<R> run() async {
    try {
      return await _offload(_bind(call, token));
    } on TailcatTimeoutException catch (e, stackTrace) {
      Error.throwWithStackTrace(
        TailcatTimeoutException(e.message, timeout),
        stackTrace,
      );
    } finally {
      native.closeToken(token);
      running._token = 0;
    }
  }

  return running = BlockingCall._(run(), token);
}

// Its own scope, so the closure captures only [call] and [token].
R Function() _bind<R>(R Function(int token) call, int token) =>
    () => call(token);

Future<R> _run<R>(Duration? timeout, R Function(int token) call) =>
    _start(timeout ?? defaultTimeout, call).result;

Future<R> _offload<R>(R Function() computation) async {
  try {
    return await Isolate.run(computation, debugName: 'libtailcat');
  } on RemoteError {
    // Only happens while the isolate group is being torn down.
    throw const TailcatClosedException('the call was abandoned');
  }
}

/// A new handle and its `tc_info` JSON, fetched in the same call.
typedef Opened = ({int handle, String info});

Opened _withInfo(int handle, int token) {
  try {
    return (handle: handle, info: native.info(handle, token));
  } catch (_) {
    native.closeHandle(handle);
    rethrow;
  }
}

/// Closes [handle] and everything under it.
Future<void> close(int handle) => _offload(() => native.closeHandle(handle));

/// Closes [children] so their FINs go out, drains up to [drainTimeout]
/// (`null` skips it), then closes [root].
Future<void> shutdown(int root, List<int> children, Duration? drainTimeout) =>
    _offload(() {
      for (final child in children) {
        native.closeHandle(child);
      }
      if (drainTimeout != null) {
        final token = native.newToken(drainTimeout);
        try {
          native.drain(root, token);
        } on TailcatException {
          // Best effort: an absent peer must not block the close.
        } finally {
          native.closeToken(token);
        }
      }
      native.closeHandle(root);
    });

/// Dials [port] on the peer of [client].
BlockingCall<Opened> dial(
  int client,
  int port,
  int network,
  Duration? timeout,
) => _start(
  timeout ?? defaultTimeout,
  (token) => _withInfo(native.dial(client, token, port, network), token),
);

/// Starts [server] and returns its `tc_info` JSON.
Future<String> startServer(int server, Duration? timeout) =>
    _run(timeout, (token) {
      native.startServer(server, token);
      return native.info(server, token);
    });

/// Listens on [port] of [server], starting it if necessary.
Future<Opened> listen(int server, int port, int network, Duration? timeout) =>
    _run(
      timeout,
      (token) => _withInfo(native.listen(server, token, port, network), token),
    );

/// Relay round-trip latency of [client] in milliseconds.
Future<int> ping(int client, Duration? timeout) =>
    _run(timeout, (token) => native.ping(client, token));

/// JSON describing the current path of [client] to its peer.
Future<String> discoPing(int client, Duration? timeout) =>
    _run(timeout, (token) => native.discoPing(client, token));

/// Adds [publicKey] to the allowlist of [server].
Future<void> allowClient(int server, String publicKey, Duration? timeout) =>
    _run(timeout, (token) => native.allowClient(server, token, publicKey));

/// Waits for the TCP stack of the client or server [handle] to drain.
Future<void> drain(int handle, Duration? timeout) => _run(
  timeout ?? defaultDrainTimeout,
  (token) => native.drain(handle, token),
);

/// Embeds the relay details in [address].
Future<String> resolveAddress(
  String address,
  String? derpMapUrl,
  Duration? timeout,
) =>
    _run(timeout, (token) => native.resolveAddress(token, address, derpMapUrl));
