// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:async';
import 'dart:typed_data';

import 'package:tin_can/src/audio/voice_engine.dart';

final class FakeInput implements AudioInput {
  bool allowed = true;
  StreamController<Uint8List>? controller;

  @override
  Future<bool> requestPermission() async => allowed;

  @override
  Future<Stream<Uint8List>> start() async =>
      (controller = StreamController<Uint8List>()).stream;

  @override
  Future<void> stop() async => controller?.close();

  @override
  Future<void> dispose() async {}
}

/// Drains instantly and asks for more on every feed or kick.
final class FakeOutput implements AudioOutput {
  late void Function(int queued) onNeedMore;
  final fed = <Int16List>[];
  int kicks = 0;

  @override
  Future<void> setup({
    required int threshold,
    required void Function(int queued) onNeedMore,
  }) async => this.onNeedMore = onNeedMore;

  @override
  void kick() {
    kicks++;
    onNeedMore(0);
  }

  @override
  Future<void> feed(Int16List samples) async => fed.add(samples);

  @override
  Future<void> dispose() async {}
}
