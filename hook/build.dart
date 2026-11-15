// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

/// Provides the native library as the code asset the bindings resolve.
library;

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:libtailcat/src/hook/native_target.dart';
import 'package:libtailcat/src/hook/resolver.dart';
import 'package:libtailcat/src/hook/user_config.dart';

/// Asset id of the generated bindings, without the package prefix.
const bindingsAssetName = 'src/bindings/tailcat_bindings.g.dart';

void main(List<String> arguments) => build(arguments, (input, output) async {
  if (!input.config.buildCodeAssets) return;
  final code = input.config.code;
  final target = NativeTarget.fromCodeConfig(code);
  final config = HookUserConfig.from(input);

  // Before the early return, so toggling skip_unsupported_targets there
  // re-runs the hook too.
  final localConfig = HookUserConfig.localConfigFile(input);
  if (localConfig != null) output.dependencies.add(localConfig.uri);

  // Without the option, the resolver fails the build.
  if (!target.isSupported && config.skipUnsupportedTargets) {
    stderr.writeln(
      'libtailcat: ${target.unsupportedReason}. Skipping the native library '
      'for $target because skip_unsupported_targets is set; every call into '
      'libtailcat will fail on this platform.',
    );
    return;
  }

  final resolved = await NativeLibraryResolver(
    target: target,
    config: config,
    packageRoot: input.packageRoot,
    outputDirectory: input.outputDirectory,
    sharedDirectory: input.outputDirectoryShared,
    cCompiler: code.cCompiler,
    log: stderr.writeln,
  ).resolve();
  if (resolved == null) return;

  output.assets.code.add(
    CodeAsset(
      package: input.packageName,
      name: bindingsAssetName,
      linkMode: DynamicLoadingBundled(),
      file: resolved.file,
    ),
  );
  output.dependencies.addAll(resolved.dependencies);
});
