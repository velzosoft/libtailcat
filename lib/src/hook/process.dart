// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:io';
import 'dart:math';

final _random = Random();

/// A temp-name suffix unique per process and per call, so isolates differ too.
String uniqueSuffix() =>
    '$pid-${DateTime.now().microsecondsSinceEpoch}-${_random.nextInt(1 << 32)}';

/// An external tool (`go`, `git`, `clang`, ...) could not be run or failed.
final class ToolException implements Exception {
  /// Creates the exception.
  const ToolException(this.message);

  /// What failed, including the tool's output.
  final String message;

  @override
  String toString() => message;
}

/// Runs [executable]; throws [ToolException] if it can't start or exits
/// non-zero.
Future<ProcessResult> runTool(
  String executable,
  List<String> arguments, {
  Map<String, String>? environment,
  String? workingDirectory,
}) async {
  final ProcessResult result;
  try {
    result = await Process.run(
      executable,
      arguments,
      environment: environment,
      workingDirectory: workingDirectory,
    );
  } on ProcessException catch (e) {
    throw ToolException('cannot run $executable: ${e.message}');
  }
  if (result.exitCode != 0) {
    throw ToolException(
      '`$executable ${arguments.join(' ')}` failed '
      '(exit ${result.exitCode})\n${result.stdout}\n${result.stderr}',
    );
  }
  return result;
}
