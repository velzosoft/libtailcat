// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

/// Pins a native release in `lib/src/hook/native_manifest.dart` from its
/// `SHA256SUMS` (`--check` only verifies).
library;

import 'dart:io';

import 'package:libtailcat/src/hook/upstream.dart';

import 'src/manifest_update.dart';

Future<void> main(List<String> args) async {
  String? sums, tag;
  var manifestPath = 'lib/src/hook/native_manifest.dart';
  var check = false;
  var allowIncomplete = false;
  for (var i = 0; i < args.length; i++) {
    String next() {
      if (i + 1 >= args.length) _usage('missing value for ${args[i]}');
      return args[++i];
    }

    switch (args[i]) {
      case '--sums':
        sums = next();
      case '--tag':
        tag = next();
      case '--manifest':
        manifestPath = next();
      case '--check':
        check = true;
      case '--allow-incomplete':
        allowIncomplete = true;
      case '--help' || '-h':
        _usage(null);
      default:
        _usage('unknown argument ${args[i]}');
    }
  }
  if (sums == null || tag == null) _usage('--sums and --tag are required');
  if (!releaseTagPattern.hasMatch(tag)) {
    _usage('--tag must look like native-<12 hex digits>-<n>');
  }
  final pin = UpstreamPin.read(Directory.current.uri);
  if (!tag.startsWith('native-${pin.shortCommit}-')) {
    _fail(
      '$tag was not built from the commit in $upstreamPinPath '
      '(${pin.shortCommit})',
    );
  }

  final Map<String, String> artifacts;
  try {
    artifacts = parseSha256Sums(await File(sums).readAsString());
  } on FormatException catch (e) {
    _fail('$sums: ${e.message}');
  }
  final (:missing, :unexpected) = checkArtifactSet(artifacts);
  for (final name in unexpected) {
    stderr.writeln('warning: $name is not a release target');
  }
  if (missing.isNotEmpty) {
    stderr.writeln('missing release targets:\n  ${missing.join('\n  ')}');
    if (!allowIncomplete) {
      _fail('incomplete release (pass --allow-incomplete to pin it anyway)');
    }
  }

  final manifest = File(manifestPath);
  final source = await manifest.readAsString();
  if (check) {
    final current = readManifest(source);
    final problems = <String>[
      if (current.tag != tag) 'tag is "${current.tag}", expected $tag',
      for (final entry in artifacts.entries)
        if (current.artifacts[entry.key] != entry.value)
          '${entry.key}: manifest has ${current.artifacts[entry.key] ?? 'nothing'}',
      for (final name in current.artifacts.keys)
        if (!artifacts.containsKey(name)) '$name: in manifest but not in $sums',
    ];
    if (problems.isNotEmpty) {
      _fail('$manifestPath is out of date:\n  ${problems.join('\n  ')}');
    }
    stdout.writeln('$manifestPath matches $sums ($tag)');
    return;
  }

  final updated = updateManifestSource(source, tag: tag, artifacts: artifacts);
  await manifest.writeAsString(updated);
  final format = await Process.run(Platform.resolvedExecutable, [
    'format',
    manifest.path,
  ]);
  if (format.exitCode != 0) _fail('dart format failed: ${format.stderr}');
  stdout.writeln(
    'pinned ${artifacts.length} artifact(s) for $tag in $manifestPath',
  );
}

Never _fail(String message) {
  stderr.writeln('error: $message');
  exit(1);
}

Never _usage(String? error) {
  if (error != null) stderr.writeln('error: $error\n');
  stderr.writeln(
    'usage: dart run tool/update_manifest.dart --sums <SHA256SUMS> '
    '--tag <native-COMMIT-N> [--manifest lib/src/hook/native_manifest.dart] '
    '[--check] [--allow-incomplete]',
  );
  exit(error == null ? 0 : 64);
}
