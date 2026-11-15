// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import '../bindings/native_api.dart' as native;
import 'blocking.dart' as blocking;
import 'errors.dart';
import 'token.dart';
import 'worker.dart';
import 'worker_stream.dart';

/// Accepted connections in flight to a paused listener.
const int acceptWindow = 16;

const _infoTimeout = Duration(seconds: 5);

/// Connections or flows accepted on [listener] by a helper isolate. [decode]
/// takes ownership of each handle; late arrivals are closed.
WorkerStream<T> acceptConnections<T>(
  int listener, {
  required T Function(blocking.Opened opened) decode,
  void Function(Object? error)? onEnded,
}) => WorkerStream<T>(
  operation: 'accept',
  onEnded: onEnded,
  decode: (event) => decode(event as blocking.Opened),
  discard: (event) =>
      blocking.close((event as blocking.Opened).handle).ignore(),
  spawn: ({required onEvent, required onExit}) => Worker.spawn(
    _acceptLoop,
    listener,
    debugName: 'libtailcat acceptor',
    onEvent: onEvent,
    onExit: onExit,
  ),
);

Future<void> _acceptLoop(WorkerContext context, int listener) async {
  final credits = Credits(context, acceptWindow);
  while (await credits.acquire()) {
    var handle = 0;
    String? error;
    final status = context.token.run((token) {
      final result = native.accept(listener, token, context.out);
      handle = context.out.handleValue;
      error = result.error;
      return result.status;
    });
    if (status == native.TC_OK) {
      final info = _describe(handle);
      if (info == null) continue;
      final blocking.Opened accepted = (handle: handle, info: info);
      context.emit(accepted);
      credits.spend();
      continue;
    }
    if (status == sliceElapsed) continue;
    context.emit(WorkerEnded(status, error));
    return;
  }
}

/// The `tc_info` JSON, or `null` (handle released) if it's already gone.
String? _describe(int connection) {
  final token = native.newToken(_infoTimeout);
  try {
    return native.info(connection, token);
  } on TailcatException {
    native.closeHandle(connection);
    return null;
  } finally {
    native.closeToken(token);
  }
}
