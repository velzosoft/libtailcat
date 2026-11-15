// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

/// Moves the pin in `native/UPSTREAM` to another upstream commit and refreshes
/// the copied files under `native/`.
library;

import 'dart:io';

import 'package:libtailcat/src/hook/process.dart';
import 'package:libtailcat/src/hook/upstream.dart';

const _copies = {
  'cmd/libtailcat/tailcat.h': 'native/tailcat.h',
  'build-tags.txt': buildTagsPath,
  'LICENSE': 'native/LICENSE.upstream',
};

Future<void> main(List<String> args) async {
  if (args.length != 1 || !RegExp(r'^[0-9a-f]{40}$').hasMatch(args.single)) {
    stderr.writeln(
      'usage: dart run tool/sync_upstream.dart <full 40-digit commit hash>',
    );
    exit(64);
  }
  final commit = args.single;
  final packageRoot = Directory.current.uri;
  final current = UpstreamPin.read(packageRoot);
  try {
    final source = await UpstreamSources(log: stderr.writeln).ensure(
      UpstreamPin(
        repository: current.repository,
        commit: commit,
        goVersion: current.goVersion,
        abiVersion: current.abiVersion,
      ),
      packageRoot.resolve('.dart_tool/libtailcat/'),
    );
    String upstream(String path) =>
        File.fromUri(source.resolve(path)).readAsStringSync();

    final goVersion = _capture(
      upstream('go.mod'),
      RegExp(r'^go (\d+\.\d+(?:\.\d+)?)$', multiLine: true),
      'the go directive of go.mod',
    );
    final abiVersion = _capture(
      upstream('internal/capi/api.go'),
      RegExp(r'^const ABIVersion = (\d+)$', multiLine: true),
      'ABIVersion in internal/capi/api.go',
    );

    for (final MapEntry(key: from, value: to) in _copies.entries) {
      File.fromUri(packageRoot.resolve(to)).writeAsStringSync(upstream(from));
    }
    final pinFile = File.fromUri(packageRoot.resolve(upstreamPinPath));
    pinFile.writeAsStringSync(
      pinFile
          .readAsStringSync()
          .replaceFirst(
            RegExp(r'^commit: .*$', multiLine: true),
            'commit: $commit',
          )
          .replaceFirst(RegExp(r'^go: .*$', multiLine: true), 'go: $goVersion')
          .replaceFirst(
            RegExp(r'^abi: .*$', multiLine: true),
            'abi: $abiVersion',
          ),
    );
    // Validates the rewrite.
    final pin = UpstreamPin.read(packageRoot);

    stdout.writeln(
      '''
Pinned $pin (Go ${pin.goVersion}, ABI ${pin.abiVersion}).

Next:
  1. git diff native/                  # review what changed upstream
  2. (cd tool/ffigen && dart run bin/generate.dart)   # if tailcat.h changed
  3. dart test                         # with "native": "source" in hook/local_config.json
  4. Run tool/smoke_app on an Android emulator and an iOS simulator.
  5. Cut a native release (see CONTRIBUTING.md).${abiVersion == '${current.abiVersion}' ? '' : '''

The ABI version changed from ${current.abiVersion} to $abiVersion: update
supportedAbiVersion in lib/src/runtime/library.dart and review every binding.'''}''',
    );
  } on ToolException catch (e) {
    stderr.writeln('error: $e');
    exit(1);
  } on FormatException catch (e) {
    stderr.writeln('error: ${e.message}');
    exit(1);
  }
}

String _capture(String text, RegExp pattern, String what) =>
    pattern.firstMatch(text)?.group(1) ??
    (throw FormatException('cannot find $what'));
