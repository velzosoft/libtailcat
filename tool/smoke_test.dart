// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

/// Runs `tool/smoke_app` on an Android device or iOS simulator and reports
/// the verdict it logs. `--hot-restart` checks that a restart gets past
/// helper isolates blocked in native calls, quickly.
///
/// Boot emulators cold with `-dns-server 8.8.8.8`: a stale snapshot can break
/// name resolution in a way that looks like a library bug.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

const _marker = 'LIBTAILCAT_SMOKE: ';
const _androidPackage = 'dev.libtailcat.libtailcat_smoke';
const _iosBundle = 'dev.libtailcat.libtailcatSmoke';

/// The helpers wait in one-second slices.
const _hotRestartLimit = Duration(seconds: 15);

late final Directory _app;

Future<void> main(List<String> args) async {
  final options = _parse(args);
  _app = Directory.fromUri(Directory.current.uri.resolve('tool/smoke_app/'));
  if (!_app.existsSync()) _fail('run this from the root of the package');
  await _configureNative(options.native);

  final device =
      options.device ??
      await switch (options.platform) {
        'android' => _firstAndroidDevice(),
        _ => _bootedSimulator(),
      };
  stderr.writeln('smoke test on ${options.platform} device $device');

  final verdict =
      await (options.hotRestart
              ? _runWithHotRestart(device, options)
              : options.platform == 'android'
              ? _runOnAndroid(device, options)
              : _runOnSimulator(device, options))
          .timeout(
            options.timeout,
            onTimeout: () =>
                _fail('no verdict within ${options.timeout.inSeconds} s'),
          );
  if (!verdict.startsWith('PASS')) _fail(verdict);
  stdout.writeln(verdict);
  exit(0);
}

Future<String> _runOnAndroid(String device, _Options options) async {
  final abi = (await _adb(device, [
    'shell',
    'getprop',
    'ro.product.cpu.abi',
  ])).trim();
  final targetPlatform = switch (abi) {
    'arm64-v8a' => 'android-arm64',
    'x86_64' => 'android-x64',
    'armeabi-v7a' => 'android-arm',
    _ => _fail('unsupported device ABI "$abi"'),
  };
  await _flutter([
    'build',
    'apk',
    '--debug',
    '--target-platform',
    targetPlatform,
    ...options.dartDefines,
  ]);
  await _adb(device, [
    'install',
    '-r',
    '${_app.path}build/app/outputs/flutter-apk/app-debug.apk',
  ]);
  await _adb(device, ['logcat', '-c']);
  await _adb(device, ['shell', 'am', 'force-stop', _androidPackage]);
  await _adb(device, [
    'shell',
    'am',
    'start',
    '-n',
    '$_androidPackage/.MainActivity',
  ]);
  final logcat = await Process.start(_adbPath, [
    '-s',
    device,
    'logcat',
    '-v',
    'raw',
    '-s',
    'flutter:*',
  ]);
  try {
    return await _verdict(_lines(logcat.stdout));
  } finally {
    logcat.kill();
  }
}

Future<String> _runOnSimulator(String device, _Options options) async {
  await _flutter([
    'build',
    'ios',
    '--simulator',
    '--debug',
    ...options.dartDefines,
  ]);
  await _run('xcrun', [
    'simctl',
    'install',
    device,
    '${_app.path}build/ios/iphonesimulator/Runner.app',
  ]);
  // Listen before launching so no line is missed.
  final log = await Process.start('xcrun', [
    'simctl',
    'spawn',
    device,
    'log',
    'stream',
    '--style',
    'compact',
    '--predicate',
    'process == "Runner" AND eventMessage CONTAINS "${_marker.trim()}"',
  ]);
  try {
    final lines = _lines(log.stdout).asBroadcastStream();
    // A header line means `log stream` is attached.
    await lines.first;
    await _run('xcrun', [
      'simctl',
      'launch',
      '--terminate-running-process',
      device,
      _iosBundle,
    ]);
    return await _verdict(lines);
  } finally {
    log.kill();
    await Process.run('xcrun', ['simctl', 'terminate', device, _iosBundle]);
  }
}

Future<String> _runWithHotRestart(String device, _Options options) async {
  final flutter = await Process.start('flutter', [
    'run',
    '-d',
    device,
    ...options.dartDefines,
  ], workingDirectory: _app.path);
  unawaited(flutter.stderr.transform(utf8.decoder).forEach(stderr.write));
  final lines = StreamIterator(_lines(flutter.stdout));
  Future<String> nextVerdict() async {
    while (await lines.moveNext()) {
      final verdict = _verdictIn(lines.current);
      if (verdict != null) return verdict;
    }
    _fail('flutter run ended without a verdict');
  }

  try {
    final first = await nextVerdict();
    if (!first.startsWith('PASS')) return first;

    final watch = Stopwatch()..start();
    flutter.stdin.write('R');
    await flutter.stdin.flush();
    final second = await nextVerdict();
    if (!second.startsWith('PASS')) return 'after hot restart: $second';
    // Subtract the time the checks themselves took.
    final elapsed = watch.elapsed;
    final restart = elapsed - _durationOf(second);
    if (restart > _hotRestartLimit) {
      return 'FAIL hot restart took ${restart.inMilliseconds} ms';
    }
    return 'PASS twice; hot restart took about ${restart.inMilliseconds} ms '
        '(first run: ${first.substring(5)})';
  } finally {
    flutter.stdin.write('q');
    await flutter.stdin.flush().catchError((Object _) {});
    await flutter.exitCode.timeout(
      const Duration(seconds: 20),
      onTimeout: () {
        flutter.kill();
        return -1;
      },
    );
  }
}

/// From `PASS in <n> ms, ...`.
Duration _durationOf(String verdict) => Duration(
  milliseconds: int.parse(
    RegExp(r'in (\d+) ms').firstMatch(verdict)?.group(1) ?? '0',
  ),
);

Stream<String> _lines(Stream<List<int>> output) => output
    .transform(const Utf8Decoder(allowMalformed: true))
    .transform(const LineSplitter());

/// Echoes the report and returns its `PASS`/`FAIL` line.
Future<String> _verdict(Stream<String> lines) async {
  await for (final line in lines) {
    final verdict = _verdictIn(line);
    if (verdict != null) return verdict;
  }
  _fail('the log ended without a verdict');
}

String? _verdictIn(String line) {
  final at = line.indexOf(_marker);
  if (at < 0) return null;
  final report = line.substring(at + _marker.length).trim();
  stderr.writeln('  $report');
  return report.startsWith('PASS') || report.startsWith('FAIL') ? report : null;
}

/// Overrides the native mode the app's pubspec sets.
Future<void> _configureNative(String native) async {
  final file = File('${_app.path}hook_config.json');
  final config = switch (native) {
    'source' => {'native': 'source'},
    'download' => {'native': 'download'},
    _ => {'native': 'local', 'path': Directory(native).absolute.path},
  };
  await file.writeAsString('${jsonEncode(config)}\n');
}

Future<String> _firstAndroidDevice() async {
  final devices = const LineSplitter()
      .convert(await _run(_adbPath, ['devices']))
      .skip(1)
      .where((line) => line.endsWith('\tdevice'))
      .map((line) => line.split('\t').first)
      .toList();
  if (devices.isEmpty) _fail('no Android device or emulator is running');
  return devices.first;
}

Future<String> _bootedSimulator() async {
  final listing =
      jsonDecode(
            await _run('xcrun', ['simctl', 'list', 'devices', 'booted', '-j']),
          )
          as Map<String, Object?>;
  final runtimes = listing['devices']! as Map<String, Object?>;
  for (final devices in runtimes.values) {
    for (final device in devices! as List<Object?>) {
      return (device! as Map<String, Object?>)['udid']! as String;
    }
  }
  _fail('no iOS simulator is booted (xcrun simctl boot <udid>)');
}

String get _adbPath {
  final sdk =
      Platform.environment['ANDROID_HOME'] ??
      Platform.environment['ANDROID_SDK_ROOT'];
  if (sdk != null) return '$sdk/platform-tools/adb';
  final home = Platform.environment['HOME'];
  final macDefault = '$home/Library/Android/sdk/platform-tools/adb';
  return File(macDefault).existsSync() ? macDefault : 'adb';
}

Future<String> _adb(String device, List<String> arguments) =>
    _run(_adbPath, ['-s', device, ...arguments]);

Future<void> _flutter(List<String> arguments) async {
  stderr.writeln('flutter ${arguments.join(' ')}');
  final process = await Process.start(
    'flutter',
    arguments,
    workingDirectory: _app.path,
    mode: ProcessStartMode.inheritStdio,
  );
  if (await process.exitCode != 0) _fail('flutter ${arguments.first} failed');
}

Future<String> _run(String executable, List<String> arguments) async {
  final result = await Process.run(executable, arguments);
  if (result.exitCode != 0) {
    _fail(
      '$executable ${arguments.join(' ')} failed:\n'
      '${result.stdout}${result.stderr}',
    );
  }
  return result.stdout as String;
}

final class _Options {
  _Options({
    required this.platform,
    required this.native,
    required this.hotRestart,
    required this.timeout,
    this.device,
    this.region,
  });

  final String platform;
  final String native;
  final bool hotRestart;
  final Duration timeout;
  final String? device;
  final String? region;

  List<String> get dartDefines => [
    if (region != null) '--dart-define=SMOKE_REGION=$region',
  ];
}

_Options _parse(List<String> args) {
  String? platform, device, region;
  var native = 'source';
  var hotRestart = false;
  var timeout = const Duration(minutes: 20);
  for (var i = 0; i < args.length; i++) {
    String next() {
      if (i + 1 >= args.length) _usage('missing value for ${args[i]}');
      return args[++i];
    }

    switch (args[i]) {
      case '--platform':
        platform = next();
      case '--device':
        device = next();
      case '--native':
        native = next();
      case '--region':
        region = next();
      case '--timeout':
        timeout = Duration(seconds: int.parse(next()));
      case '--hot-restart':
        hotRestart = true;
      case '--help' || '-h':
        _usage(null);
      default:
        _usage('unknown argument ${args[i]}');
    }
  }
  if (platform != 'android' && platform != 'ios') {
    _usage('--platform must be android or ios');
  }
  return _Options(
    platform: platform!,
    device: device,
    native: native,
    region: region,
    hotRestart: hotRestart,
    timeout: timeout,
  );
}

Never _fail(String message) {
  stderr.writeln('smoke test failed: $message');
  exit(1);
}

Never _usage(String? error) {
  if (error != null) stderr.writeln('error: $error\n');
  stderr.writeln(
    'usage: dart run tool/smoke_test.dart --platform <android|ios> '
    '[--device <id>] [--hot-restart] '
    '[--native source|download|<directory with a prebuilt library>] '
    '[--region <DERPRegion JSON, to use a relay of your own>] '
    '[--timeout <seconds>]',
  );
  exit(error == null ? 0 : 64);
}
