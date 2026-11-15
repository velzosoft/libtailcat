// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:async';

import 'blocking.dart' as blocking;
import 'errors.dart';

/// Closes a native handle and its native subtree.
typedef NativeCloser = Future<void> Function(int handle);

/// The Dart object a [NativeHandle] belongs to.
abstract interface class HandleOwner {
  /// Called once, synchronously, when this or an ancestor is closed. Stop
  /// workers and complete streams; don't use the handle again.
  void handleRetired();
}

/// A node mirroring the native resource tree, where closing a node closes
/// its subtree.
///
/// The native handle is closed once; every descendant's owner is told so its
/// streams don't hang. A finalizer closes handles of collected owners as a
/// best-effort safety net.
final class NativeHandle {
  /// Wraps handle [id] of [owner]. [closer] replaces the native close (tests
  /// pass a fake).
  NativeHandle(
    this.id,
    HandleOwner owner, {
    NativeHandle? parent,
    NativeCloser? closer,
  }) : _owner = WeakReference(owner),
       _parent = parent,
       _closer = closer ?? parent?._closer ?? blocking.close {
    assert(parent == null || !parent.isClosed, 'the parent is closed');
    parent?._children.add(this);
    _whenClosed.future.ignore();
    _finalizer.attach(owner, this, detach: this);
  }

  static final Finalizer<NativeHandle> _finalizer = Finalizer(
    (handle) => handle.close().ignore(),
  );

  /// The native `tc_handle`.
  final int id;

  // Weak, or the finalizer could never fire for an abandoned owner.
  final WeakReference<HandleOwner> _owner;
  final NativeHandle? _parent;
  final NativeCloser _closer;
  final Set<NativeHandle> _children = {};
  final Completer<void> _whenClosed = Completer<void>();
  bool _retired = false;

  /// Whether the handle has been closed, directly or through an ancestor.
  bool get isClosed => _retired;

  /// The native handle; throws [TailcatClosedException] once closed.
  int get checked {
    if (_retired) throw const TailcatClosedException();
    return id;
  }

  /// The native handles of all descendants that are still open.
  List<int> get descendants => [
    for (final child in _children) ...[child.id, ...child.descendants],
  ];

  /// Closes the handle and its descendants, which are retired synchronously.
  /// Idempotent. [using] replaces the native close for this call.
  Future<void> close({NativeCloser? using}) {
    if (_retired) return _whenClosed.future;
    _parent?._children.remove(this);
    final retired = <NativeHandle>[];
    _retire(retired);
    _closeNatively(using ?? _closer, retired);
    return _whenClosed.future;
  }

  void _retire(List<NativeHandle> retired) {
    _retired = true;
    _finalizer.detach(this);
    retired.add(this);
    for (final child in _children) {
      child._retire(retired);
    }
    _children.clear();
    _owner.target?.handleRetired();
  }

  Future<void> _closeNatively(
    NativeCloser closer,
    List<NativeHandle> retired,
  ) async {
    Object? error;
    StackTrace? stackTrace;
    try {
      // One native close covers the whole subtree.
      await closer(id);
    } catch (e, s) {
      error = e;
      stackTrace = s;
    }
    for (final node in retired) {
      // Only the node that was asked to close reports a failure.
      if (identical(node, this) && error != null) {
        node._whenClosed.completeError(error, stackTrace);
      } else {
        node._whenClosed.complete();
      }
    }
  }
}
