// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:convert';
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';
import 'package:libtailcat/src/hook/artifact_download.dart';
import 'package:libtailcat/src/hook/go_build.dart';
import 'package:libtailcat/src/hook/native_manifest.dart';
import 'package:libtailcat/src/hook/native_target.dart';
import 'package:libtailcat/src/hook/process.dart';
import 'package:libtailcat/src/hook/resolver.dart';
import 'package:libtailcat/src/hook/upstream.dart';
import 'package:libtailcat/src/hook/user_config.dart';
import 'package:test/test.dart';

import '../../hook/build.dart' as hook;

const _macArm = NativeTarget(os: OS.macOS, architecture: Architecture.arm64);
const _linuxX64 = NativeTarget(os: OS.linux, architecture: Architecture.x64);
const _windowsX64 = NativeTarget(
  os: OS.windows,
  architecture: Architecture.x64,
);
const _androidArm64 = NativeTarget(
  os: OS.android,
  architecture: Architecture.arm64,
);
const _iosSimulatorX64 = NativeTarget(
  os: OS.iOS,
  architecture: Architecture.x64,
  iosSdk: IOSSdk.iPhoneSimulator,
);

void main() {
  group('NativeTarget', () {
    test('names its artifact and the bundled file', () {
      expect(_macArm.artifactFileName, 'libtailcat-macos-arm64.dylib');
      expect(_macArm.libraryFileName, 'libtailcat.dylib');
      expect(_linuxX64.artifactFileName, 'libtailcat-linux-x64.so');
      expect(_windowsX64.artifactFileName, 'libtailcat-windows-x64.dll');
      expect(_windowsX64.libraryFileName, 'libtailcat.dll');
      expect(_androidArm64.libraryFileName, 'libtailcat.so');
      expect(
        _iosSimulatorX64.artifactFileName,
        'libtailcat-ios-x64-iphonesimulator.dylib',
      );
    });

    test('maps to GOOS and GOARCH', () {
      expect((_macArm.goos, _macArm.goarch), ('darwin', 'arm64'));
      expect((_windowsX64.goos, _windowsX64.goarch), ('windows', 'amd64'));
      expect(_iosSimulatorX64.goos, 'ios');
      const arm = NativeTarget(os: OS.android, architecture: Architecture.arm);
      expect((arm.goos, arm.goarch), ('android', 'arm'));
    });

    test('release targets are supported and uniquely named', () {
      final names = {
        for (final target in NativeTarget.releaseTargets)
          target.artifactFileName,
      };
      expect(names, hasLength(NativeTarget.releaseTargets.length));
      expect(NativeTarget.releaseTargets, everyElement(_isSupported));
    });

    test('knows what it is not built for', () {
      const windowsArm = NativeTarget(
        os: OS.windows,
        architecture: Architecture.arm64,
      );
      const iosDeviceX64 = NativeTarget(
        os: OS.iOS,
        architecture: Architecture.x64,
        iosSdk: IOSSdk.iPhoneOS,
      );
      const androidX86 = NativeTarget(
        os: OS.android,
        architecture: Architecture.ia32,
      );
      for (final target in [windowsArm, iosDeviceX64, androidX86]) {
        expect(target.isSupported, isFalse, reason: '$target');
        expect(target.unsupportedReason, contains('not built for'));
      }
      expect(() => androidX86.goarch, throwsUnsupportedError);
    });

    test('never targets below the supported minimums', () {
      const old = NativeTarget(
        os: OS.macOS,
        architecture: Architecture.arm64,
        macosVersion: 11,
        iosVersion: 12,
        androidNdkApi: 21,
      );
      expect(old.effectiveMacosVersion, NativeTarget.minimumMacosVersion);
      expect(old.effectiveIosVersion, NativeTarget.minimumIosVersion);
      expect(old.effectiveAndroidApi, NativeTarget.minimumAndroidApi);
      const recent = NativeTarget(
        os: OS.macOS,
        architecture: Architecture.arm64,
        macosVersion: 15,
        iosVersion: 17,
        androidNdkApi: 35,
      );
      expect(recent.effectiveMacosVersion, 15);
      expect(recent.effectiveIosVersion, 17);
      expect(recent.effectiveAndroidApi, 35);
    });
  });

  group('GoBuildPlan', () {
    final source = Uri.directory('/src/tailcat');
    final out = Uri.directory('/out');

    GoBuildPlan plan(
      NativeTarget target, {
      CCompilerConfig? cCompiler,
      String? iosSdkPath,
      String? macosSdkPath,
      Uri? androidPatch,
    }) => GoBuildPlan.forTarget(
      target,
      sourceDir: source,
      outputDir: out,
      buildTags: 'ts_omit_a,ts_omit_b\n',
      goToolchain: 'go1.27.2+auto',
      cCompiler: cCompiler,
      iosSdkPath: iosSdkPath,
      macosSdkPath: macosSdkPath,
      androidPatch: androidPatch,
    );

    final ndk = CCompilerConfig(
      compiler: Uri.file('/ndk/bin/clang'),
      linker: Uri.file('/ndk/bin/ld'),
      archiver: Uri.file('/ndk/bin/ar'),
    );

    test('every build is trimmed, tagged and pinned to a toolchain', () {
      final step = plan(_linuxX64).steps.single;
      expect(step.executable, 'go');
      expect(step.workingDirectory, _filePath('/src/tailcat/'));
      expect(
        step.arguments,
        containsAllInOrder([
          'build',
          '-trimpath',
          '-tags',
          'ts_omit_a,ts_omit_b',
          '-ldflags',
          '-s -w -buildid=',
          '-buildmode=c-shared',
          '-o',
          _filePath('/out/libtailcat.so'),
          './cmd/libtailcat',
        ]),
      );
      expect(step.environment, containsPair('CGO_ENABLED', '1'));
      expect(step.environment, containsPair('GOTOOLCHAIN', 'go1.27.2+auto'));
      expect(step.environment, containsPair('GOFLAGS', '-mod=readonly'));
      expect(step.environment, containsPair('GOOS', 'linux'));
      expect(step.environment, containsPair('GOARCH', 'amd64'));
    });

    test('macOS declares its deployment target and a relocatable name', () {
      final built = plan(_macArm, macosSdkPath: '/sdk/MacOSX.sdk');
      final env = built.steps.single.environment;
      expect(built.outputFile.path, '/out/libtailcat.dylib');
      expect(env['MACOSX_DEPLOYMENT_TARGET'], '13.0');
      expect(env['SDKROOT'], '/sdk/MacOSX.sdk');
      expect(
        env['CGO_CFLAGS'],
        '-mmacosx-version-min=13.0 -isysroot /sdk/MacOSX.sdk',
      );
      expect(
        env['CGO_LDFLAGS'],
        allOf(
          contains('-Wl,-headerpad_max_install_names'),
          contains('-Wl,-install_name,@rpath/libtailcat.dylib'),
        ),
      );
      expect(
        plan(_macArm).steps.single.environment,
        isNot(contains('SDKROOT')),
      );
    });

    test('Android compiles the patch in and aligns to 16 KB pages', () {
      final patch = Uri.file('/pkg/native/patches/android_ifaces.go');
      final built = plan(_androidArm64, cCompiler: ndk, androidPatch: patch);
      final step = built.steps.single;
      expect(built.patches, [androidPatchPath]);
      expect(step.environment['CC'], _filePath('/ndk/bin/clang'));
      expect(
        step.environment['CGO_CFLAGS'],
        '--target=aarch64-linux-android24',
      );
      expect(
        step.environment['CGO_LDFLAGS'],
        allOf(
          contains('-Wl,-z,max-page-size=16384'),
          contains('-Wl,-soname,libtailcat.so'),
        ),
      );
      expect(
        step.arguments,
        containsAllInOrder([
          '-overlay',
          _filePath('/out/overlay-android.json'),
        ]),
      );

      final overlay = built.extraFiles.single;
      expect(overlay.path.path, '/out/overlay-android.json');
      expect(jsonDecode(overlay.contents), {
        'Replace': {
          _filePath('/src/tailcat/cmd/libtailcat/$androidPatchOverlayName'):
              _filePath(patch.path),
        },
      });
    });

    test('Android cannot be planned without the NDK or the patch', () {
      expect(
        () => plan(_androidArm64, androidPatch: Uri.file('/p.go')),
        throwsStateError,
      );
      expect(() => plan(_androidArm64, cCompiler: ndk), throwsStateError);
    });

    test('Android 32-bit ARM targets ARMv7', () {
      const arm = NativeTarget(os: OS.android, architecture: Architecture.arm);
      final env = plan(
        arm,
        cCompiler: ndk,
        androidPatch: Uri.file('/p.go'),
      ).steps.single.environment;
      expect(env['GOARM'], '7');
      expect(env['CGO_CFLAGS'], '--target=armv7a-linux-androideabi24');
    });

    test('iOS builds an archive, then links the dylib by hand', () {
      final built = plan(
        _iosSimulatorX64,
        iosSdkPath: '/sdk/iPhoneSimulator.sdk',
      );
      expect(built.steps, hasLength(2));
      final [archive, link] = built.steps;

      expect(archive.arguments, contains('-buildmode=c-archive'));
      expect(archive.environment['GOOS'], 'ios');
      expect(
        archive.environment['CC'],
        _filePath('/out/clangwrap-iphonesimulator-x86_64.sh'),
      );
      final wrapper = built.extraFiles.single;
      expect(wrapper.executable, isTrue);
      expect(
        wrapper.contents,
        allOf(
          contains('-arch x86_64'),
          contains('-isysroot "/sdk/iPhoneSimulator.sdk"'),
          contains('-mios-simulator-version-min=13.0'),
        ),
      );

      expect(link.executable, 'xcrun');
      expect(
        link.arguments,
        containsAll([
          '-dynamiclib',
          '-Wl,-headerpad_max_install_names',
          '-Wl,-force_load,'
              '${_filePath('/out/libtailcat-iphonesimulator-x86_64.a')}',
          '@rpath/libtailcat.dylib',
          _filePath('/out/libtailcat.dylib'),
        ]),
      );
    });

    test('an iOS device uses the iphoneos flags', () {
      const device = NativeTarget(
        os: OS.iOS,
        architecture: Architecture.arm64,
        iosSdk: IOSSdk.iPhoneOS,
        iosVersion: 16,
      );
      final built = plan(device, iosSdkPath: '/sdk/iPhoneOS.sdk');
      expect(
        built.extraFiles.single.contents,
        contains('-miphoneos-version-min=16.0'),
      );
      expect(() => plan(device), throwsStateError);
    });

    test('Windows leaves the compiler to Go, which wants MinGW', () {
      final step = plan(_windowsX64, cCompiler: ndk).steps.single;
      expect(step.environment, isNot(contains('CC')));
      expect(step.arguments, contains(_filePath('/out/libtailcat.dll')));
    });

    test('an unsupported target cannot be planned', () {
      expect(
        () => plan(
          const NativeTarget(os: OS.windows, architecture: Architecture.arm64),
        ),
        throwsUnsupportedError,
      );
    });
  });

  group('UpstreamPin', () {
    const text = '''
# a comment
repository: https://github.com/tailscale/tailcat
commit: e00cdde6ff787f801361ff85ed085775c775d4c5

go: 1.27.2
abi: 1
''';

    test('parses the pin file', () {
      final pin = UpstreamPin.parse(text);
      expect(pin.repository, 'https://github.com/tailscale/tailcat');
      expect(pin.commit, 'e00cdde6ff787f801361ff85ed085775c775d4c5');
      expect(pin.shortCommit, 'e00cdde6ff78');
      expect(pin.goVersion, '1.27.2');
      expect(pin.goToolchain, 'go1.27.2+auto');
      expect(pin.abiVersion, 1);
    });

    test('rejects a missing or malformed value', () {
      for (final broken in [
        text.replaceFirst('commit: e00cdde6', 'commit: E00CDDE6'),
        text.replaceFirst(RegExp(r'go: .*'), ''),
        text.replaceFirst('abi: 1', 'abi: one'),
        '$text\nnot a key value line',
      ]) {
        expect(() => UpstreamPin.parse(broken), throwsFormatException);
      }
    });

    test('the committed pin matches the bindings and the vendored files', () {
      final root = Directory.current.uri;
      final pin = UpstreamPin.read(root);
      expect(pin.abiVersion, 1);
      for (final path in [
        'native/tailcat.h',
        buildTagsPath,
        'native/LICENSE.upstream',
        androidPatchPath,
      ]) {
        expect(
          File.fromUri(root.resolve(path)).existsSync(),
          isTrue,
          reason: path,
        );
      }
    });
  });

  group('UpstreamSources', () {
    late Directory temp;
    late UpstreamPin pin;
    late Uri cache;
    late Uri checkout;

    Future<String> git(Directory dir, List<String> arguments) async {
      final result = await runTool(
        'git',
        arguments,
        workingDirectory: dir.path,
      );
      return (result.stdout as String).trim();
    }

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('libtailcat_upstream_');
      final origin = Directory.fromUri(temp.uri.resolve('origin/'))
        ..createSync();
      File.fromUri(
        origin.uri.resolve('go.mod'),
      ).writeAsStringSync('module example\n');
      await git(origin, ['init', '-q']);
      await git(origin, ['add', '.']);
      await git(origin, [
        '-c', 'user.name=test', '-c', 'user.email=test@example.com', //
        '-c', 'commit.gpgsign=false', 'commit', '-q', '-m', 'initial',
      ]);
      pin = UpstreamPin(
        repository: origin.uri.toString(),
        commit: await git(origin, ['rev-parse', 'HEAD']),
        goVersion: '1.27.2',
        abiVersion: 1,
      );
      cache = temp.uri.resolve('cache/');
      checkout = cache.resolve('tailcat-src-${pin.commit}/');
    });

    tearDown(() => temp.delete(recursive: true));

    void expectOnlyTheCheckout() {
      // Trimmed: git may check out CRLF on Windows.
      expect(
        File.fromUri(checkout.resolve('go.mod')).readAsStringSync().trim(),
        'module example',
      );
      expect(Directory.fromUri(cache).listSync().map((e) => e.uri), [
        checkout,
      ], reason: 'no partial checkout is left behind');
    }

    test('concurrent callers share one complete checkout', () async {
      final sources = UpstreamSources(log: (_) {});
      final dirs = await Future.wait([
        for (var i = 0; i < 6; i++) sources.ensure(pin, cache),
      ]);
      expect(dirs, everyElement(checkout));
      expectOnlyTheCheckout();
    });

    test('replaces a partial checkout and then reuses it', () async {
      Directory.fromUri(checkout).createSync(recursive: true);
      File.fromUri(checkout.resolve('stale')).writeAsStringSync('');
      final logged = <String>[];
      final sources = UpstreamSources(log: logged.add);
      expect(await sources.ensure(pin, cache), checkout);
      expect(File.fromUri(checkout.resolve('stale')).existsSync(), isFalse);
      expectOnlyTheCheckout();
      expect(await sources.ensure(pin, cache), checkout);
      expect(logged, hasLength(1), reason: 'the second call fetches nothing');
    });
  });

  group('HookUserConfig', () {
    HookUserConfig resolve(Map<String, Object?> defines) =>
        HookUserConfig.resolve(
          value: (key) => defines[key],
          path: (key) => switch (defines[key]) {
            final String path => Uri.file('/app/').resolve(path),
            _ => null,
          },
        );

    test('downloads by default', () {
      final config = resolve({});
      expect(config.mode, NativeMode.download);
      expect(config.allowMissingNative, isFalse);
      expect(config.skipUnsupportedTargets, isFalse);
    });

    test('reads every knob', () {
      final config = resolve({
        'native': 'source',
        'cache_dir': '.cache',
        'source_dir': '../tailcat',
        'go': '/opt/go/bin/go',
        'go_toolchain': 'local',
        'allow_missing_native': 'true',
        'skip_unsupported_targets': true,
      });
      expect(config.mode, NativeMode.source);
      expect(config.cacheDir, Uri.file('/app/.cache/'));
      expect(config.sourceDir, Uri.file('/tailcat/'));
      expect(config.goExecutable, '/opt/go/bin/go');
      expect(config.goToolchain, 'local');
      expect(config.allowMissingNative, isTrue);
      expect(config.skipUnsupportedTargets, isTrue);
    });

    test('local mode needs a path', () {
      expect(
        resolve({'native': 'local', 'path': 'libs'}).localPath,
        Uri.file('/app/libs'),
      );
      expect(() => resolve({'native': 'local'}), throwsA(isA<BuildError>()));
    });

    test('rejects a mode it does not know', () {
      expect(
        () => resolve({'native': 'magic'}),
        throwsA(
          isA<BuildError>().having(
            (e) => e.message,
            'message',
            allOf(contains('magic'), contains('download, local, source')),
          ),
        ),
      );
    });

    test('the local override file resolves paths next to itself', () async {
      final temp = await Directory.systemTemp.createTemp('libtailcat-config');
      addTearDown(() => temp.delete(recursive: true));
      final file = File('${temp.path}/hook/local_config.json');
      await file.create(recursive: true);
      expect(LocalHookConfig.read(File('${temp.path}/missing.json')), isNull);

      await file.writeAsString('{"native": "source", "source_dir": "../up"}');
      final local = LocalHookConfig.read(file)!;
      expect(local.has('native'), isTrue);
      expect(local.has('go'), isFalse);
      expect(local.value('native'), 'source');
      expect(local.path('source_dir'), File('${temp.path}/up').absolute.uri);

      await file.writeAsString('[]');
      expect(() => LocalHookConfig.read(file), throwsA(isA<BuildError>()));
      await file.writeAsString('{');
      expect(() => LocalHookConfig.read(file), throwsA(isA<BuildError>()));
    });
  });

  group('downloads', () {
    late HttpServer server;
    late Directory temp;
    late int requests;
    final content = utf8.encode('pretend this is a shared library');
    final digest = sha256.convert(content).toString();

    setUp(() async {
      requests = 0;
      temp = await Directory.systemTemp.createTemp('libtailcat-download');
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) {
        requests++;
        if (request.uri.path.contains('/missing/')) {
          request.response.statusCode = HttpStatus.notFound;
        } else {
          request.response.add(content);
        }
        request.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
      await temp.delete(recursive: true);
    });

    Uri url(String path) => Uri.parse('http://127.0.0.1:${server.port}/$path');

    ArtifactDownloader downloader() =>
        ArtifactDownloader(cacheDir: temp.uri.resolve('cache/'), log: (_) {});

    test('are verified, cached and reused', () async {
      final first = await downloader().fetch(
        url: url('v1/lib.so'),
        expectedSha256: digest,
        fileName: 'lib.so',
      );
      expect(await first.readAsBytes(), content);
      final second = await downloader().fetch(
        url: url('v1/lib.so'),
        expectedSha256: digest,
        fileName: 'lib.so',
      );
      expect(second.path, first.path);
      expect(requests, 1, reason: 'the second fetch is served from the cache');
    });

    test(
      'with the wrong content are rejected and leave nothing behind',
      () async {
        await expectLater(
          downloader().fetch(
            url: url('v1/lib.so'),
            expectedSha256: '0' * 64,
            fileName: 'lib.so',
          ),
          throwsA(
            isA<ChecksumMismatch>()
                .having((e) => e.actual, 'actual', digest)
                .having((e) => e.expected, 'expected', '0' * 64),
          ),
        );
        expect(Directory('${temp.path}/cache').listSync(), isEmpty);
      },
    );

    test('that fail are reported as I/O errors', () async {
      await expectLater(
        downloader().fetch(
          url: url('missing/lib.so'),
          expectedSha256: digest,
          fileName: 'lib.so',
        ),
        throwsA(isA<HttpException>()),
      );
      expect(Directory('${temp.path}/cache').listSync(), isEmpty);
    });

    test('a corrupted cache entry is downloaded again', () async {
      final cached = await downloader().fetch(
        url: url('v1/lib.so'),
        expectedSha256: digest,
        fileName: 'lib.so',
      );
      await cached.writeAsString('tampered');
      final again = await downloader().fetch(
        url: url('v1/lib.so'),
        expectedSha256: digest,
        fileName: 'lib.so',
      );
      expect(await again.readAsBytes(), content);
      expect(requests, 2);
    });

    group('through the resolver', () {
      NativeLibraryResolver resolver({
        required NativeManifest manifest,
        HookUserConfig config = const HookUserConfig(),
        NativeTarget target = _linuxX64,
        List<String>? log,
      }) => NativeLibraryResolver(
        target: target,
        config: config,
        packageRoot: Directory.current.uri,
        outputDirectory: temp.uri.resolve('out/'),
        sharedDirectory: temp.uri.resolve('shared/'),
        manifest: manifest,
        log: (message) => log?.add(message),
      );

      NativeManifest manifest(String tag, {String? sha}) => NativeManifest(
        releaseTag: tag,
        baseUrl: 'http://127.0.0.1:${server.port}',
        artifacts: {_linuxX64.artifactFileName: sha ?? digest},
      );

      test('the pinned artifact is installed under the bundled name', () async {
        final resolved = await resolver(manifest: manifest('v1')).resolve();
        expect(resolved!.mode, NativeMode.download);
        expect(resolved.file.path, endsWith('/out/libtailcat.so'));
        expect(await File.fromUri(resolved.file).readAsBytes(), content);
        expect(resolved.dependencies, isNotEmpty);
      });

      test('cache_dir replaces the shared directory', () async {
        final cache = temp.uri.resolve('my-cache/');
        await resolver(
          manifest: manifest('v1'),
          config: HookUserConfig(cacheDir: cache),
        ).resolve();
        expect(Directory.fromUri(cache).listSync(), hasLength(1));
        expect(Directory('${temp.path}/shared').existsSync(), isFalse);
      });

      test(
        'a checksum mismatch fails the build, whatever is allowed',
        () async {
          for (final allow in [false, true]) {
            await expectLater(
              resolver(
                manifest: manifest('v1', sha: 'f' * 64),
                config: HookUserConfig(allowMissingNative: allow),
              ).resolve(),
              throwsA(
                isA<BuildError>().having(
                  (e) => e.message,
                  'message',
                  contains('checksum mismatch'),
                ),
              ),
            );
          }
        },
      );

      test('a failed download fails the build and says what to do', () async {
        await expectLater(
          resolver(manifest: manifest('missing')).resolve(),
          throwsA(
            isA<BuildError>().having(
              (e) => e.message,
              'message',
              allOf(contains('native: local'), contains('native: source')),
            ),
          ),
        );
      });

      test('allow_missing_native tolerates a failed download', () async {
        final log = <String>[];
        final resolved = await resolver(
          manifest: manifest('missing'),
          config: const HookUserConfig(allowMissingNative: true),
          log: log,
        ).resolve();
        expect(resolved, isNull);
        expect(log.join('\n'), contains('allow_missing_native'));
      });

      test('a target the release lacks fails with the alternatives', () async {
        const empty = NativeManifest(
          releaseTag: '',
          baseUrl: '',
          artifacts: {},
        );
        await expectLater(
          resolver(manifest: empty).resolve(),
          throwsA(
            isA<BuildError>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('libtailcat-linux-x64'),
                contains('native: source'),
                contains('native: local'),
              ),
            ),
          ),
        );
        expect(
          await resolver(
            manifest: empty,
            config: const HookUserConfig(allowMissingNative: true),
          ).resolve(),
          isNull,
        );
      });

      test('an unsupported target always fails', () async {
        await expectLater(
          resolver(
            manifest: manifest('v1'),
            config: const HookUserConfig(allowMissingNative: true),
            target: const NativeTarget(
              os: OS.windows,
              architecture: Architecture.arm64,
            ),
          ).resolve(),
          throwsA(
            isA<BuildError>().having(
              (e) => e.message,
              'message',
              contains('skip_unsupported_targets'),
            ),
          ),
        );
      });

      test('local mode takes a file, or finds one in a directory', () async {
        final libs = Directory('${temp.path}/libs')..createSync();
        final generic = File('${libs.path}/libtailcat.so')
          ..writeAsStringSync('generic');
        NativeLibraryResolver local(Uri path) => resolver(
          manifest: manifest('v1'),
          config: HookUserConfig(mode: NativeMode.local, localPath: path),
        );
        Future<String> installed(Uri path) async =>
            File.fromUri((await local(path).resolve())!.file).readAsString();

        expect(await installed(generic.uri), 'generic');
        expect(await installed(libs.uri), 'generic');
        File('${libs.path}/libtailcat-linux-x64.so').writeAsStringSync('exact');
        expect(await installed(libs.uri), 'exact');
        expect(requests, 0, reason: 'local mode never downloads');

        await expectLater(
          local(temp.uri.resolve('nowhere/')).resolve(),
          throwsA(isA<BuildError>()),
        );
        final emptyDir = Directory('${temp.path}/empty')..createSync();
        await expectLater(
          local(emptyDir.uri).resolve(),
          throwsA(
            isA<BuildError>().having(
              (e) => e.message,
              'message',
              contains('libtailcat-linux-x64.so'),
            ),
          ),
        );
      });
    });
  });

  group('hook/build.dart', () {
    PackageUserDefines defines(Map<String, Object?> values) =>
        PackageUserDefines(
          workspacePubspec: PackageUserDefinesSource(
            // Ignore the developer's hook/local_config.json.
            defines: {'local_config': 'none.json', ...values},
            basePath: Directory.current.uri,
          ),
        );

    test('bundles a local library as the asset the bindings resolve', () async {
      final temp = await Directory.systemTemp.createTemp('libtailcat-hook');
      addTearDown(() => temp.delete(recursive: true));
      final target = NativeTarget(
        os: OS.current,
        architecture: Architecture.current,
      );
      File(
        '${temp.path}/${target.libraryFileName}',
      ).writeAsStringSync('not really a library');
      await testCodeBuildHook(
        mainMethod: hook.main,
        userDefines: defines({'native': 'local', 'path': temp.path}),
        check: (input, output) {
          final asset = output.assets.code.single;
          expect(
            asset.id,
            'package:libtailcat/src/bindings/tailcat_bindings.g.dart',
          );
          expect(asset.linkMode, isA<DynamicLoadingBundled>());
          expect(asset.file!.path, endsWith('/${target.libraryFileName}'));
          expect(File.fromUri(asset.file!).existsSync(), isTrue);
          expect(output.dependencies, isNotEmpty);
        },
      );
    });

    // The unset case is tested on the resolver: a BuildError makes the hooks
    // package call exit(), killing the test runner.
    test('skip_unsupported_targets emits nothing for such a target', () async {
      await testCodeBuildHook(
        mainMethod: hook.main,
        targetOS: OS.windows,
        targetArchitecture: Architecture.arm64,
        userDefines: defines({'skip_unsupported_targets': true}),
        check: (input, output) {
          expect(output.assets.code, isEmpty);
          expect(
            output.dependencies,
            contains(Directory.current.uri.resolve('none.json')),
            reason: 'the local config still re-runs the hook',
          );
        },
      );
    });

    test(
      'allow_missing_native emits nothing while no release is pinned',
      () async {
        if (nativeArtifacts.isNotEmpty) {
          markTestSkipped('a native release is pinned');
          return;
        }
        await testCodeBuildHook(
          mainMethod: hook.main,
          userDefines: defines({'allow_missing_native': true}),
          check: (input, output) => expect(output.assets.code, isEmpty),
        );
      },
    );
  });
}

/// [posixPath] in host form, so expectations hold on Windows.
String _filePath(String posixPath) =>
    Uri.parse('file://$posixPath').toFilePath();

final Matcher _isSupported = isA<NativeTarget>().having(
  (target) => target.isSupported,
  'isSupported',
  isTrue,
);
