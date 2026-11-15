// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:async';

import 'package:libtailcat/libtailcat.dart';
import 'package:libtailcat/src/runtime/handle.dart';
import 'package:test/test.dart';

final class _Owner implements HandleOwner {
  _Owner(this.name, this.log);

  final String name;
  final List<String> log;

  @override
  void handleRetired() => log.add('retired $name');
}

void main() {
  late List<String> log;
  late List<int> closed;
  // The tree holds owners weakly; this keeps them alive.
  late List<_Owner> owners;

  Future<void> closer(int handle) async {
    closed.add(handle);
    log.add('closed $handle');
  }

  NativeHandle node(
    int id,
    String name, {
    NativeHandle? parent,
    NativeCloser? using,
  }) {
    final owner = _Owner(name, log);
    owners.add(owner);
    return NativeHandle(id, owner, parent: parent, closer: using ?? closer);
  }

  setUp(() {
    log = [];
    closed = [];
    owners = [];
  });

  test('a handle is usable until it is closed', () async {
    final handle = node(7, 'client');
    expect(handle.isClosed, isFalse);
    expect(handle.checked, 7);

    final closing = handle.close();
    // Retired before the native close finishes.
    expect(handle.isClosed, isTrue);
    expect(() => handle.checked, throwsA(isA<TailcatClosedException>()));
    await closing;
    expect(log, ['retired client', 'closed 7']);
  });

  test('closing twice closes the native handle once', () async {
    final handle = node(7, 'client');
    final first = handle.close();
    final second = handle.close();
    expect(second, same(first));
    await Future.wait([first, second, handle.close()]);
    expect(closed, [7]);
    expect(log.where((entry) => entry.startsWith('retired')), hasLength(1));
  });

  test(
    'closing a parent retires the whole subtree with one native close',
    () async {
      final server = node(1, 'server');
      final listener = node(2, 'listener', parent: server);
      final first = node(3, 'socket a', parent: server);
      final second = node(4, 'socket b', parent: server);
      expect(server.descendants, unorderedEquals([2, 3, 4]));

      await server.close();

      for (final handle in [server, listener, first, second]) {
        expect(handle.isClosed, isTrue);
      }
      expect(
        log.where((entry) => entry.startsWith('retired')),
        unorderedEquals([
          'retired server',
          'retired listener',
          'retired socket a',
          'retired socket b',
        ]),
      );
      // Native close of the parent takes the children with it.
      expect(closed, [1]);
      await first.close();
      expect(closed, [1]);
      expect(server.descendants, isEmpty);
    },
  );

  test('closing a child leaves its siblings and its parent open', () async {
    final server = node(1, 'server');
    final listener = node(2, 'listener', parent: server);
    final socket = node(3, 'socket', parent: server);

    await listener.close();

    expect(listener.isClosed, isTrue);
    expect(socket.isClosed, isFalse);
    expect(server.isClosed, isFalse);
    expect(closed, [2]);
    expect(server.descendants, [3]);

    await server.close();
    expect(closed, [2, 1]);
    expect(log.where((entry) => entry == 'retired listener'), hasLength(1));
  });

  test('a replacement closer runs instead of the default one', () async {
    final server = node(1, 'server');
    node(2, 'socket', parent: server);
    final steps = <String>[];
    await server.close(using: (id) async => steps.add('shutdown $id'));
    expect(steps, ['shutdown 1']);
    expect(closed, isEmpty);
  });

  test('a failing native close reaches the caller and nobody else', () async {
    final failure = StateError('native close failed');
    final server = node(1, 'server', using: (_) async => throw failure);
    final socket = node(2, 'socket', parent: server);

    await expectLater(server.close(), throwsA(same(failure)));
    expect(server.isClosed, isTrue);
    await socket.close();
    // An unawaited failing close must not become an uncaught error.
    final ignored = node(3, 'other', using: (_) async => throw failure);
    unawaited(ignored.close());
    await Future<void>.delayed(Duration.zero);
  });
}
