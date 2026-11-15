// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'blocking.dart' as blocking;
import 'errors.dart';
import 'handle.dart';

/// The native client or server at the root of a resource tree.
///
/// Children hold a reference to it so the finalizer never closes a peer under
/// a live socket.
final class Peer implements HandleOwner {
  /// Wraps the native client or server handle [id].
  Peer(int id) {
    handle = NativeHandle(id, this);
  }

  /// The root handle.
  late final NativeHandle handle;

  /// Whether the peer has been closed.
  bool get isClosed => handle.isClosed;

  /// Releases [child] and throws [TailcatClosedException] if the peer closed
  /// while the call that returned it was in flight.
  void checkAdoptable(int child) {
    if (!isClosed) return;
    blocking.close(child).ignore();
    throw const TailcatClosedException();
  }

  /// Waits for the TCP stack to finish its shutdown traffic.
  Future<void> drain(Duration? timeout) =>
      blocking.drain(handle.checked, timeout);

  /// Closes the peer and its subtree. With [drain], children close first and
  /// their FINs get up to [drainTimeout] to go out.
  Future<void> close({required bool drain, Duration? drainTimeout}) {
    final children = handle.descendants;
    final timeout = drain ? drainTimeout ?? blocking.defaultDrainTimeout : null;
    return handle.close(
      using: (id) => blocking.shutdown(id, children, timeout),
    );
  }

  @override
  void handleRetired() {}
}
