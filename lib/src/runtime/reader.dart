// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../bindings/native_api.dart' as native;
import 'token.dart';
import 'worker.dart';
import 'worker_stream.dart';

/// Size of the native buffer one read fills.
const int readChunkSize = 64 * 1024;

/// Chunks in flight to a paused listener; bounds its buffering.
const int readWindow = 4;

/// Bytes from [connection], read on a helper isolate. With [datagram], each
/// event is exactly one datagram, empty ones included.
WorkerStream<Uint8List> readConnection(
  int connection, {
  required bool datagram,
  void Function(Object? error)? onEnded,
}) => WorkerStream<Uint8List>(
  operation: 'read',
  onEnded: onEnded,
  decode: (event) =>
      (event as TransferableTypedData).materialize().asUint8List(),
  spawn: ({required onEvent, required onExit}) => Worker.spawn(
    _readLoop,
    (connection: connection, datagram: datagram),
    debugName: 'libtailcat reader',
    onEvent: onEvent,
    onExit: onExit,
  ),
);

typedef _ReadParameters = ({int connection, bool datagram});

Future<void> _readLoop(
  WorkerContext context,
  _ReadParameters parameters,
) async {
  final credits = Credits(context, readWindow);
  final buffer = malloc<Uint8>(readChunkSize);
  try {
    while (await credits.acquire()) {
      var count = 0;
      String? error;
      final status = context.token.run((token) {
        final result = native.read(
          parameters.connection,
          token,
          buffer,
          readChunkSize,
          context.out,
        );
        count = context.out.countValue;
        error = result.error;
        return result.status;
      });
      // Bytes can come with a non-OK status; deliver them first.
      if (count > 0 || (parameters.datagram && status == native.TC_OK)) {
        context.emit(
          TransferableTypedData.fromList([buffer.asTypedList(count)]),
        );
        credits.spend();
      }
      if (status == native.TC_OK || status == sliceElapsed) continue;
      context.emit(WorkerEnded(status, error));
      return;
    }
  } finally {
    malloc.free(buffer);
  }
}
