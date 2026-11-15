// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

/// A typed, stateless view of the `tc_*` C ABI. Only "local" calls are safe
/// on a responsive isolate; the rest block and belong on a worker.
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../runtime/errors.dart';
import 'tailcat_bindings.g.dart';

export 'tailcat_bindings.g.dart'
    show
        TC_CANCELLED,
        TC_CLOSED,
        TC_EOF,
        TC_FAILURE,
        TC_INVALID_ARGUMENT,
        TC_OK,
        TC_TCP,
        TC_TIMEOUT,
        TC_UDP;

/// The largest UDP payload the tunnel carries (`tailcat.MaxUDPPayload`).
const int maxDatagramSize = 1232;

/// Out-parameter storage: the `char **error` slot plus one result slot read
/// as whatever type the call returns.
final class OutParams {
  /// Allocates the storage; release it with [free].
  OutParams() : _slots = calloc<Uint64>(2);

  final Pointer<Uint64> _slots;

  /// The `char **error` argument.
  Pointer<Pointer<Char>> get error => _slots.cast();

  /// The result slot as a `char **`.
  Pointer<Pointer<Char>> get text => (_slots + 1).cast();

  /// The result slot as a `tc_handle *`.
  Pointer<Uint64> get handle => _slots + 1;

  /// The result slot as a `size_t *`.
  Pointer<Size> get count => (_slots + 1).cast();

  /// The result slot as an `int32_t *`.
  Pointer<Int32> get int32 => (_slots + 1).cast();

  /// The handle the last call stored in the result slot.
  int get handleValue => handle.value;

  /// The byte count the last call stored in the result slot.
  int get countValue => count.value;

  /// The `int32` the last call stored in the result slot.
  int get int32Value => int32.value;

  /// Takes ownership of the error message the last call left, if any.
  String? takeError() => _take(error);

  /// Takes ownership of the string the last call returned.
  String takeText() => _take(text) ?? '';

  /// Releases the storage.
  void free() => calloc.free(_slots);

  static String? _take(Pointer<Pointer<Char>> slot) {
    final value = slot.value;
    if (value == nullptr) return null;
    slot.value = nullptr;
    try {
      return value.cast<Utf8>().toDartString();
    } finally {
      // Allocated by the library's C runtime, so only tc_free may release it.
      tc_free(value.cast());
    }
  }
}

/// The outcome of a loop call, whose non-OK statuses are normal.
typedef NativeResult = ({int status, String? error});

R _withOut<R>(R Function(OutParams out) body) {
  final out = OutParams();
  try {
    return body(out);
  } finally {
    out.free();
  }
}

R _withCString<R>(String value, R Function(Pointer<Char> pointer) body) {
  final pointer = value.toNativeUtf8();
  try {
    return body(pointer.cast());
  } finally {
    malloc.free(pointer);
  }
}

/// Throws the exception for [status] unless it is `TC_OK`.
void _check(int status, OutParams out, String operation) {
  final message = out.takeError();
  if (status != TC_OK) {
    throw exceptionForStatus(status, operation: operation, message: message);
  }
}

// --- Local calls: no network access, safe on any isolate -------------------

/// The C ABI version of the loaded library. Local.
int abiVersion() => tc_abi_version();

/// JSON with the ABI version and Go build metadata. Local.
String buildInfo() => _withOut((out) {
  _check(tc_build_info(out.text, out.error), out, 'build info');
  return out.takeText();
});

/// JSON with a fresh private key, its public key and a pre-shared key. Local.
String generateKeys() => _withOut((out) {
  _check(tc_key_generate(out.text, out.error), out, 'key generation');
  return out.takeText();
});

/// JSON with the public metadata of [address]. Local.
String parseAddress(String address) => _withOut(
  (out) => _withCString(address, (pointer) {
    _check(tc_address_parse(pointer, out.text, out.error), out, 'address');
    return out.takeText();
  }),
);

/// Creates a client from its JSON configuration. Local; the network starts
/// on first use.
int newClient(String configJson) => _withOut(
  (out) => _withCString(configJson, (pointer) {
    _check(tc_client_new(pointer, out.handle, out.error), out, 'client');
    return out.handleValue;
  }),
);

/// Creates an unstarted server from its JSON configuration. Local.
int newServer(String configJson) => _withOut(
  (out) => _withCString(configJson, (pointer) {
    _check(tc_server_new(pointer, out.handle, out.error), out, 'server');
    return out.handleValue;
  }),
);

/// Creates a token expiring [timeout] from now (never when `null`). Local.
int newToken(Duration? timeout) => _withOut((out) {
  final nanoseconds = switch (timeout) {
    null => -1,
    Duration(isNegative: true) => 0,
    // Beyond int64 nanoseconds (about 292 years).
    Duration(inDays: > 100000) => -1,
    _ => timeout.inMicroseconds * 1000,
  };
  _check(tc_token_new(nanoseconds, out.handle, out.error), out, 'token');
  return out.handleValue;
});

/// Cancels the work using [token]. Never throws, since cancelling a
/// released token is a normal race. Local.
void cancelToken(int token) {
  if (token != TC_NO_CANCEL) tc_token_cancel(token, nullptr);
}

/// Releases [token]. Never throws. Local.
void closeToken(int token) {
  if (token != TC_NO_CANCEL) tc_close(token, nullptr);
}

// --- Blocking calls: run on a worker, bounded by a token --------------------

/// Retires [handle] and its subtree, interrupting and joining calls in
/// flight (no timeout). Already-retired handles are fine.
void closeHandle(int handle) => _withOut((out) {
  final status = tc_close(handle, out.error);
  final message = out.takeError();
  if (status != TC_OK && status != TC_CLOSED) {
    throw exceptionForStatus(status, operation: 'close', message: message);
  }
});

/// Dials [port] on the client's peer; returns the connection handle.
int dial(int client, int token, int port, int network) => _withOut((out) {
  _check(
    tc_client_dial(client, token, port, network, out.handle, out.error),
    out,
    'connect',
  );
  return out.handleValue;
});

/// Starts [server]; a repeated start is a no-op.
void startServer(int server, int token) => _withOut(
  (out) => _check(tc_server_start(server, token, out.error), out, 'start'),
);

/// Starts [server] if needed and listens on [port] (0 picks a free one);
/// returns the listener handle.
int listen(int server, int token, int port, int network) => _withOut((out) {
  _check(
    tc_server_listen(server, token, port, network, out.handle, out.error),
    out,
    'listen',
  );
  return out.handleValue;
});

/// JSON describing [handle]; the fields depend on its kind.
String info(int handle, int token) => _withOut((out) {
  _check(tc_info(handle, token, out.text, out.error), out, 'info');
  return out.takeText();
});

/// Round-trip latency over the relay path, in whole milliseconds.
int ping(int client, int token) => _withOut((out) {
  _check(tc_client_ping(client, token, out.int32, out.error), out, 'ping');
  return out.int32Value;
});

/// JSON describing the current path to the peer.
String discoPing(int client, int token) => _withOut((out) {
  _check(
    tc_client_disco_ping(client, token, out.text, out.error),
    out,
    'disco ping',
  );
  return out.takeText();
});

/// Adds [publicKey] to the server's allowlist.
void allowClient(int server, int token, String publicKey) => _withOut(
  (out) => _withCString(
    publicKey,
    (pointer) => _check(
      tc_server_allow_client(server, token, pointer, out.error),
      out,
      'allow client',
    ),
  ),
);

/// Waits for [handle]'s TCP stack to finish its shutdown traffic.
void drain(int handle, int token) =>
    _withOut((out) => _check(tc_drain(handle, token, out.error), out, 'drain'));

/// Returns [address] with its relay embedded, fetching [derpMapUrl] if
/// needed.
String resolveAddress(int token, String address, String? derpMapUrl) =>
    _withOut(
      (out) => _withCString(
        address,
        (addressPointer) => _withCString(derpMapUrl ?? '', (urlPointer) {
          _check(
            tc_address_resolve(
              token,
              addressPointer,
              urlPointer,
              out.text,
              out.error,
            ),
            out,
            'resolve',
          );
          return out.takeText();
        }),
      ),
    );

// --- Loop calls: statuses are data, the caller owns the OutParams ----------

/// Waits for a connection on [listener]. On `TC_OK` the handle is
/// `out.handleValue`.
NativeResult accept(int listener, int token, OutParams out) {
  final status = tc_listener_accept(listener, token, out.handle, out.error);
  return (status: status, error: out.takeError());
}

/// Reads into [buffer]. `out.countValue` holds bytes even on a non-OK
/// status; process them first.
NativeResult read(
  int connection,
  int token,
  Pointer<Uint8> buffer,
  int capacity,
  OutParams out,
) {
  final status = tc_conn_read(
    connection,
    token,
    buffer.cast(),
    capacity,
    out.count,
    out.error,
  );
  return (status: status, error: out.takeError());
}

/// Writes [length] bytes from [buffer]. `out.countValue` holds bytes sent
/// whatever the status; never replay them.
NativeResult write(
  int connection,
  int token,
  Pointer<Uint8> buffer,
  int length,
  OutParams out,
) {
  final status = tc_conn_write(
    connection,
    token,
    buffer.cast(),
    length,
    out.count,
    out.error,
  );
  return (status: status, error: out.takeError());
}

/// Half-closes a TCP [connection] once pending writes are through.
NativeResult closeWrite(int connection, int token, OutParams out) {
  final status = tc_conn_close_write(connection, token, out.error);
  return (status: status, error: out.takeError());
}
