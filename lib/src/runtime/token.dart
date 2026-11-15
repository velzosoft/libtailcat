// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../bindings/native_api.dart' as native;

/// The longest a worker stays inside one native call.
///
/// The VM can't kill an isolate inside an FFI call, so an unbounded wait
/// would hang hot restart and VM shutdown. Blocking loops wait in slices and
/// check their [CancelSlot] in between.
const sliceDuration = Duration(seconds: 1);

/// Pseudo-status of [SlicedToken.run]: the slice elapsed; try again. Keeps
/// `TC_TIMEOUT` for timeouts the native library raised itself.
const int sliceElapsed = -1;

/// Native memory shared by a worker and its owner: the worker's current
/// token and a stop flag. A worker blocked in a native call can't receive
/// messages, so the owner cancels through this.
///
/// No atomics: a race only delays the stop by one slice, and a stale cancel
/// is harmless because handles are never reused.
final class CancelSlot {
  /// Allocates a slot; the owner [free]s it once the worker is gone.
  CancelSlot.allocate() : _words = calloc<Uint64>(2);

  /// The worker's view of the slot the owner allocated at [address].
  CancelSlot.fromAddress(int address) : _words = Pointer.fromAddress(address);

  final Pointer<Uint64> _words;

  /// The address to hand to the worker.
  int get address => _words.address;

  /// Whether the owner asked the worker to stop.
  bool get isCancelled => _words[1] != 0;

  /// Worker side: records the token of the call about to start, or 0.
  void publish(int token) => _words[0] = token;

  /// Owner side: asks the worker to stop and interrupts its native call.
  void cancel() {
    _words[1] = 1;
    native.cancelToken(_words[0]);
  }

  /// Owner side: releases the memory, only after the worker has exited.
  void free() => calloc.free(_words);
}

/// Worker side of slicing: runs native calls with a token that expires after
/// [sliceDuration] and is reused until then, published in a [CancelSlot].
final class SlicedToken {
  /// Creates the slicer for a worker whose owner holds [slot].
  SlicedToken(this._slot);

  final CancelSlot _slot;
  final Stopwatch _age = Stopwatch();
  int _token = 0;

  /// Runs one bounded attempt of [call]: its status, [sliceElapsed], or
  /// `TC_CANCELLED` once the owner cancelled.
  int run(int Function(int token) call) {
    if (_slot.isCancelled) return native.TC_CANCELLED;
    if (_token == 0) {
      _age
        ..reset()
        ..start();
      _token = native.newToken(sliceDuration);
      _slot.publish(_token);
      // The owner may have cancelled before the publish.
      if (_slot.isCancelled) return native.TC_CANCELLED;
    }
    final status = call(_token);
    if (status == native.TC_TIMEOUT || status == native.TC_CANCELLED) {
      // The stopwatch started before the token, so a slice timeout always
      // shows a full slice elapsed.
      final expired = _age.elapsed >= sliceDuration;
      _release();
      if (status == native.TC_TIMEOUT && expired) return sliceElapsed;
      if (_slot.isCancelled) return native.TC_CANCELLED;
    }
    return status;
  }

  /// Releases the current token.
  void dispose() => _release();

  void _release() {
    if (_token == 0) return;
    _slot.publish(0);
    native.closeToken(_token);
    _token = 0;
  }
}
