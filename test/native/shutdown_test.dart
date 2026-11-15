// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

@Tags(['native'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../support/native.dart';

void main() {
  // An isolate inside an FFI call can't be killed, so an unbounded native
  // wait would block exit and Flutter hot restart.
  test(
    'the VM shuts down promptly with helpers blocked in native calls',
    () async {
      final relay = await TestRelay.start();
      addTearDown(relay.stop);
      final process = await Process.start(Platform.resolvedExecutable, [
        'run',
        'test/support/abrupt_exit.dart',
        jsonEncode(relay.region),
      ]);
      final exited = process.exitCode;
      final errors = process.stderr.transform(utf8.decoder).join();
      final ready = Completer<void>();
      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            if (line == 'ready' && !ready.isCompleted) ready.complete();
          });
      await Future.any([
        ready.future,
        exited.then(
          (code) async => fail('exited early ($code): ${await errors}'),
        ),
      ]);

      final watch = Stopwatch()..start();
      try {
        await exited.timeout(const Duration(seconds: 10));
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
        fail('still running 10 s after its main isolate ended');
      }
      // One slice, plus the VM's own shutdown.
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    },
    skip: hermeticUnavailable,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
