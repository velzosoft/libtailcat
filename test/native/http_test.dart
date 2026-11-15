// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

@Tags(['native'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';

import '../support/native.dart';

void main() {
  group('HTTP over a tunnel', () {
    late Tunnel tunnel;
    late HttpClient client;

    setUpAll(() async {
      tunnel = await Tunnel.open();
      client = HttpClient()
        ..connectionFactory = tunnel.client.connectionFactory;
      addTearDown(() => client.close(force: true));
    });

    Future<Uri> serve(void Function(HttpRequest request) handler) async {
      final listener = await tunnel.server.listen();
      final server = HttpServer.listenOn(listener)..listen(handler);
      addTearDown(() async {
        await server.close(force: true);
        await listener.close();
      });
      // The host is only a label; requests go to the client's server.
      return Uri.parse('http://tailcat:${listener.port}/');
    }

    Future<String> body(HttpClientResponse response) =>
        utf8.decodeStream(response);

    group('HttpServer.listenOn with HttpClient.connectionFactory', () {
      test('serves a GET and echoes a POST', () async {
        final base = await serve((request) async {
          final text = await utf8.decodeStream(request);
          request.response
            ..headers.contentType = ContentType.text
            ..write('${request.method} ${request.uri.path} [$text]');
          await request.response.close();
        });

        final get = await (await client.getUrl(base.resolve('/hello'))).close();
        expect(get.statusCode, HttpStatus.ok);
        expect(await body(get), 'GET /hello []');

        final post = await client.postUrl(base.resolve('/echo'));
        post.write('a body');
        expect(await body(await post.close()), 'POST /echo [a body]');
      });

      test('reuses one connection for consecutive requests', () async {
        final ports = <int>{};
        final base = await serve((request) {
          ports.add(request.connectionInfo!.remotePort);
          request.response
            ..write('ok')
            ..close();
        });
        for (var i = 0; i < 3; i++) {
          expect(await body(await (await client.getUrl(base)).close()), 'ok');
          // HttpClient pools the connection only once the request is
          // acknowledged as written, which can trail the response.
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(ports, hasLength(1));
      });

      test('streams a large response body', () async {
        const size = 3 * 1024 * 1024;
        final base = await serve((request) async {
          request.response.contentLength = size;
          final block = List<int>.filled(64 * 1024, 0x61);
          for (var sent = 0; sent < size; sent += block.length) {
            request.response.add(block);
            await request.response.flush();
          }
          await request.response.close();
        });
        final response = await (await client.getUrl(base)).close();
        final length = await response.fold<int>(
          0,
          (sum, data) => sum + data.length,
        );
        expect(length, size);
      });

      test('upgrades to a WebSocket', () async {
        final base = await serve((request) async {
          final socket = await WebSocketTransformer.upgrade(request);
          socket.listen(
            (message) => socket.add('echo: $message'),
            onDone: socket.close,
          );
        });
        final socket = await WebSocket.connect(
          base.replace(scheme: 'ws').toString(),
          customClient: client,
        );
        socket
          ..add('one')
          ..add('two');
        expect(await socket.take(2).toList(), ['echo: one', 'echo: two']);
        await socket.close();
      });

      test('refuses https, which cannot be layered on a tunnel', () async {
        await expectLater(
          client.getUrl(Uri.parse('https://tailcat/')),
          throwsUnsupportedError,
        );
      });
    });

    test('a shelf handler serves over a tunnel', () async {
      final listener = await tunnel.server.listen();
      final server = HttpServer.listenOn(listener);
      shelf_io.serveRequests(
        server,
        const shelf.Pipeline()
            .addMiddleware(shelf.logRequests(logger: (_, _) {}))
            .addHandler(
              (request) => shelf.Response.ok('shelf says ${request.url.path}'),
            ),
      );
      addTearDown(() async {
        await server.close(force: true);
        await listener.close();
      });
      final response = await (await client.getUrl(
        Uri.parse('http://tailcat:${listener.port}/hi'),
      )).close();
      expect(await body(response), 'shelf says hi');
    });
  }, skip: hermeticUnavailable);
}
