// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

/// Regenerates `lib/src/bindings/tailcat_bindings.g.dart` from
/// `native/tailcat.h`. Committed so consumers never need libclang.
library;

import 'dart:io';

import 'package:ffigen/ffigen.dart';
import 'package:path/path.dart' as p;

const _assetId = 'package:libtailcat/src/bindings/tailcat_bindings.g.dart';

const _handleTypes = {'tc_handle', 'tc_token'};

const _preamble = '''
// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause
//
// GENERATED FILE. Do not edit by hand.
// Regenerate with: cd tool/ffigen && dart run bin/generate.dart
//
// Bindings to the `tc_*` C ABI of https://github.com/tailscale/tailcat
// (cmd/libtailcat/tailcat.h, vendored as native/tailcat.h). Every function
// except tc_abi_version and tc_free returns a TC_* status code.

// ignore_for_file: type=lint
''';

Future<void> main(List<String> args) async {
  var packageRoot = p.normalize(p.join(Directory.current.path, '..', '..'));
  String? header;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--package-root' when i + 1 < args.length:
        packageRoot = p.normalize(p.absolute(args[++i]));
      case '--header' when i + 1 < args.length:
        header = p.normalize(p.absolute(args[++i]));
      default:
        stderr.writeln('unknown or incomplete argument: ${args[i]}');
        exit(64);
    }
  }
  header ??= p.join(packageRoot, 'native', 'tailcat.h');
  if (!File(header).existsSync()) {
    stderr.writeln('header not found: $header');
    exit(66);
  }
  final outFile = p.join(
    packageRoot,
    'lib',
    'src',
    'bindings',
    'tailcat_bindings.g.dart',
  );

  await FfiGenerator(
    input: Input(entryPoints: [Uri.file(header)]),
    output: Output(
      dart: DartOutput(path: Uri.file(outFile)),
      style: const NativeExternalBindings(assetId: _assetId),
      preamble: _preamble,
    ),
    visitors: [
      Visitor(
        // Not `isLeaf`: every cgo export may block, and a leaf call would
        // keep the isolate group from reaching a safepoint meanwhile.
        func: (node) => node.isIncluded = node.originalName.startsWith('tc_'),
        // The TC_* status and network constants are anonymous enums.
        unnamedEnumConstant: (node) =>
            node.isIncluded = node.originalName.startsWith('TC_'),
        macroConstant: (node) =>
            node.isIncluded = node.originalName == 'TC_NO_CANCEL',
        // Every other typedef the header pulls in is libc's.
        typealias: (node) =>
            node.isIncluded = _handleTypes.contains(node.originalName)
            ? TypealiasInclude.ifUsed
            : TypealiasInclude.never,
      ),
    ],
  ).generate();
  stdout.writeln('wrote $outFile');
}
