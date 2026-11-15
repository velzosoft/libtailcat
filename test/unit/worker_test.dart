// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:async';

import 'package:libtailcat/libtailcat.dart';
import 'package:libtailcat/src/bindings/tailcat_bindings.g.dart';
import 'package:libtailcat/src/runtime/worker.dart';
import 'package:libtailcat/src/runtime/worker_stream.dart';
import 'package:test/test.dart';

// The loops make no native call, so these run without the native library.
void main() {
  WorkerStream<int> counting(
    _CountParameters parameters, {
    void Function(Object? error)? onEnded,
    void Function(Object event)? discard,
  }) => WorkerStream<int>(
    operation: 'count',
    decode: (event) => event as int,
    discard: discard,
    onEnded: onEnded,
    spawn: ({required onEvent, required onExit}) => Worker.spawn(
      _count,
      parameters,
      debugName: 'test worker',
      onEvent: onEvent,
      onExit: onExit,
    ),
  );

  test('a worker stream delivers what the loop emits, then ends', () async {
    Object? endedWith = 'not called';
    final stream = counting((
      items: 5,
      window: 2,
      endStatus: TC_EOF,
    ), onEnded: (error) => endedWith = error);
    expect(await stream.stream.toList(), [0, 1, 2, 3, 4]);
    expect(stream.hasEnded, isTrue);
    expect(endedWith, isNull);
  });

  test('a paused listener holds the loop at its window', () async {
    final stream = counting((items: 100, window: 3, endStatus: TC_EOF));
    final received = <int>[];
    final done = Completer<void>();
    final subscription = stream.stream.listen(
      received.add,
      onDone: done.complete,
    );
    subscription.pause();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(received, isEmpty);

    subscription.resume();
    await done.future;
    expect(received, List.generate(100, (i) => i));
    await subscription.cancel();
  });

  test('the loop never runs further ahead than its credit', () async {
    final events = <Object>[];
    final worker = Worker.spawn(
      _count,
      (items: 100, window: 4, endStatus: TC_EOF),
      debugName: 'test worker',
      onEvent: events.add,
      onExit: (_) {},
    );
    Future<void> settle() =>
        Future<void>.delayed(const Duration(milliseconds: 300));

    await settle();
    // No credit handed back, so the loop stopped at its window.
    expect(events, [0, 1, 2, 3]);
    worker.send(2);
    await settle();
    expect(events, [0, 1, 2, 3, 4, 5]);
    worker.send(1);
    await settle();
    expect(events, [0, 1, 2, 3, 4, 5, 6]);

    worker.stop();
    await worker.exited;
    expect(events, hasLength(7));
  });

  test(
    'a failure status ends the stream with the matching exception',
    () async {
      Object? endedWith;
      final stream = counting((
        items: 2,
        window: 4,
        endStatus: TC_FAILURE,
      ), onEnded: (error) => endedWith = error);
      final events = <Object>[];
      final done = Completer<void>();
      stream.stream.listen(
        events.add,
        onError: events.add,
        onDone: done.complete,
      );
      await done.future;
      expect(events.take(2), [0, 1]);
      expect(events.last, isA<TailcatFailureException>());
      expect(endedWith, same(events.last));
    },
  );

  test('closed and cancelled end the stream without an error', () async {
    for (final status in [TC_CLOSED, TC_CANCELLED]) {
      final stream = counting((items: 1, window: 4, endStatus: status));
      expect(await stream.stream.toList(), [0]);
    }
  });

  test(
    'stop ends the stream and the worker, and discards late items',
    () async {
      final discarded = <Object>[];
      var endedCount = 0;
      final stream = counting(
        (items: 1 << 30, window: 8, endStatus: TC_EOF),
        onEnded: (_) => endedCount++,
        discard: discarded.add,
      );
      final received = <int>[];
      final done = Completer<void>();
      stream.stream.listen((item) {
        received.add(item);
        if (item == 2) stream.stop();
      }, onDone: done.complete);
      await done.future;
      stream.stop();
      expect(received, [0, 1, 2]);
      expect(endedCount, 1);
      // In-flight items are released, not silently dropped.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(discarded, everyElement(isA<int>()));
    },
  );

  test('cancelling the subscription stops the worker', () async {
    var ended = false;
    final stream = counting((
      items: 1 << 30,
      window: 8,
      endStatus: TC_EOF,
    ), onEnded: (_) => ended = true);
    expect(await stream.stream.first, 0);
    expect(ended, isTrue);
    expect(stream.hasEnded, isTrue);
  });

  test('a stream that was stopped before anyone listened is empty', () async {
    final stream = counting((items: 5, window: 2, endStatus: TC_EOF))..stop();
    expect(await stream.stream.toList(), isEmpty);
  });

  test('a worker that dies reports it instead of hanging', () async {
    final stream = WorkerStream<int>(
      operation: 'count',
      decode: (event) => event as int,
      spawn: ({required onEvent, required onExit}) => Worker.spawn(
        _crash,
        0,
        debugName: 'test worker',
        onEvent: onEvent,
        onExit: onExit,
      ),
    );
    await expectLater(stream.stream.toList(), throwsA(isA<StateError>()));
  });

  test('commands reach a worker in order, and stop ends it', () async {
    final echoed = <Object>[];
    final exited = Completer<Object?>();
    final worker = Worker.spawn(
      _echo,
      0,
      debugName: 'test worker',
      onEvent: echoed.add,
      onExit: exited.complete,
    );
    // Sent before the worker starts: buffered, not lost.
    for (var i = 0; i < 5; i++) {
      worker.send('command $i');
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(echoed, [for (var i = 0; i < 5; i++) 'command $i']);
    worker
      ..stop()
      ..stop();
    expect(await exited.future, isNull);
    await worker.exited;
  });
}

typedef _CountParameters = ({int items, int window, int endStatus});

/// Emits `0 .. items - 1` under credit control, then ends with `endStatus`.
Future<void> _count(WorkerContext context, _CountParameters parameters) async {
  final credits = Credits(context, parameters.window);
  for (var i = 0; i < parameters.items; i++) {
    if (!await credits.acquire()) return;
    context.emit(i);
    credits.spend();
  }
  context.emit(WorkerEnded(parameters.endStatus, 'done counting'));
}

Future<void> _crash(WorkerContext context, int _) async {
  throw StateError('boom');
}

Future<void> _echo(WorkerContext context, int _) async {
  while (true) {
    final command = await context.nextCommand();
    if (command == null) return;
    context.emit(command);
  }
}
