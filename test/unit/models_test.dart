// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:libtailcat/libtailcat.dart';
import 'package:libtailcat/src/bindings/tailcat_bindings.g.dart';
import 'package:libtailcat/src/config.dart';
import 'package:libtailcat/src/info.dart';
import 'package:libtailcat/src/json.dart';
import 'package:libtailcat/src/runtime/errors.dart';
import 'package:libtailcat/src/validation.dart';
import 'package:test/test.dart';

void main() {
  group('secrets', () {
    const address = TailcatAddress('tcSECRETADDRESS');
    const privateKey = TailcatPrivateKey('privkey:SECRET');
    const presharedKey = TailcatPresharedKey('psk-SECRET');

    test('never print their value', () {
      expect('$address', 'TailcatAddress(<redacted>)');
      expect('$privateKey', 'TailcatPrivateKey(<redacted>)');
      expect('$presharedKey', 'TailcatPresharedKey(<redacted>)');
      expect('${[address, privateKey]}', isNot(contains('SECRET')));
    });

    test('reveal it on request', () {
      expect(address.reveal(), 'tcSECRETADDRESS');
      expect(privateKey.reveal(), 'privkey:SECRET');
    });

    test('compare by value and by kind', () {
      expect(address, const TailcatAddress('tcSECRETADDRESS'));
      expect(
        address.hashCode,
        const TailcatAddress('tcSECRETADDRESS').hashCode,
      );
      expect(address, isNot(const TailcatAddress('other')));
      expect(
        const TailcatPrivateKey('same'),
        isNot(const TailcatPresharedKey('same')),
      );
    });

    test('stay out of the text of the objects that hold them', () {
      const keys = TailcatKeys(
        privateKey: privateKey,
        publicKey: 'nodekey:public',
        presharedKey: presharedKey,
      );
      const client = TailcatClientConfig(
        address: address,
        privateKey: privateKey,
      );
      const server = TailcatServerConfig(
        privateKey: privateKey,
        presharedKey: presharedKey,
        region: {'RegionID': 900},
      );
      for (final text in ['$keys', '$client', '$server']) {
        expect(text, isNot(contains('SECRET')));
      }
      expect('$keys', contains('nodekey:public'));
    });
  });

  group('configuration encoding', () {
    test('a client sends only what is set', () {
      expect(
        jsonDecode(
          encodeClientConfig(
            const TailcatClientConfig(address: TailcatAddress('tcA')),
          ),
        ),
        {'address': 'tcA'},
      );
      expect(
        jsonDecode(
          encodeClientConfig(
            const TailcatClientConfig(
              address: TailcatAddress('tcA'),
              privateKey: TailcatPrivateKey('privkey:1'),
              derpMapUrl: 'none',
            ),
          ),
        ),
        {'address': 'tcA', 'key': 'privkey:1', 'derp_map_url': 'none'},
      );
    });

    test('an empty server configuration is an empty object', () {
      expect(encodeServerConfig(const TailcatServerConfig()), '{}');
    });

    test('a server uses the field names of the C ABI', () {
      const region = {
        'RegionID': 900,
        'Nodes': [
          {'Name': 'a', 'HostName': 'derp.example.com'},
        ],
      };
      expect(
        jsonDecode(
          encodeServerConfig(
            const TailcatServerConfig(
              privateKey: TailcatPrivateKey('privkey:1'),
              presharedKey: TailcatPresharedKey('psk'),
              regionId: 7,
              region: region,
              derpMapUrl: 'https://example.com/map.json',
              allowedClients: ['nodekey:a', 'nodekey:b'],
              udpIdleTimeout: Duration(milliseconds: 1500),
            ),
          ),
        ),
        {
          'key': 'privkey:1',
          'preshared_key': 'psk',
          'region_id': 7,
          'region': region,
          'derp_map_url': 'https://example.com/map.json',
          'allowed_clients': ['nodekey:a', 'nodekey:b'],
          // Seconds.
          'udp_idle_timeout': 1.5,
        },
      );
    });
  });

  group('status codes', () {
    TailcatException error(int status, [String? message]) =>
        exceptionForStatus(status, operation: 'connect', message: message);

    test('map onto the sealed exception hierarchy', () {
      expect(error(TC_INVALID_ARGUMENT), isA<TailcatArgumentException>());
      expect(error(TC_CLOSED), isA<TailcatClosedException>());
      expect(error(TC_TIMEOUT), isA<TailcatTimeoutException>());
      expect(error(TC_CANCELLED), isA<TailcatCancelledException>());
      expect(error(TC_FAILURE), isA<TailcatFailureException>());
      // Unknown statuses are failures too.
      expect(error(99), isA<TailcatFailureException>());
    });

    test('are IOExceptions, and a timeout is a TimeoutException', () {
      expect(error(TC_FAILURE), isA<IOException>());
      const timeout = TailcatTimeoutException(
        'connect failed',
        Duration(seconds: 3),
      );
      expect(timeout, isA<TimeoutException>());
      expect(timeout.duration, const Duration(seconds: 3));
      expect(error(TC_TIMEOUT), isA<TimeoutException>());
    });

    test('carry the native message behind the operation', () {
      expect(error(TC_FAILURE).message, 'connect failed');
      expect(error(TC_FAILURE, '').message, 'connect failed');
      expect(error(TC_FAILURE, 'no route').message, 'connect: no route');
      expect(
        '${error(TC_CLOSED, 'gone')}',
        'TailcatClosedException: connect: gone',
      );
    });

    test('make a switch over the exception exhaustive', () {
      // Compiles only while every subclass is listed.
      String name(TailcatException e) => switch (e) {
        TailcatArgumentException() => 'argument',
        TailcatClosedException() => 'closed',
        TailcatTimeoutException() => 'timeout',
        TailcatCancelledException() => 'cancelled',
        TailcatFailureException() => 'failure',
      };
      expect(name(const TailcatClosedException()), 'closed');
    });
  });

  group('tc_info documents', () {
    test('endpoints parse IPv4 and bracketed IPv6', () {
      final v4 = Endpoint.parse('100.64.0.1:8080');
      expect(v4.address.address, '100.64.0.1');
      expect(v4.port, 8080);
      expect('$v4', '100.64.0.1:8080');

      final v6 = Endpoint.parse('[fd7a:115c:a1e0::1]:443');
      expect(v6.address.type, InternetAddressType.IPv6);
      expect(v6.port, 443);
      expect('$v6', '[fd7a:115c:a1e0::1]:443');
    });

    test('a malformed endpoint is a failure, not a crash', () {
      for (final bad in ['', 'no-port', 'host:port', 'example.com:80', ':80']) {
        expect(
          () => Endpoint.parse(bad),
          throwsA(isA<TailcatFailureException>()),
          reason: bad,
        );
      }
    });

    test('a connection has two ends', () {
      final ends = connectionEndpoints(
        '{"local_address":"[fd7a::1]:1","remote_address":"[fd7a::2]:40000",'
        '"network":1}',
      );
      expect(ends.local.port, 1);
      expect(ends.remote.port, 40000);
    });

    test('a server reports its address, key and tunnel IP', () {
      final info = ServerInfo.fromJson(
        '{"address":"tcA","public_key":"nodekey:1","local_address":"fd7a::1"}',
      );
      expect(info.address, 'tcA');
      expect(info.publicKey, 'nodekey:1');
      expect(info.localAddress.address, 'fd7a::1');
    });

    test('a missing field is reported without quoting the document', () {
      expect(
        () => ServerInfo.fromJson('{"address":"tcSECRET"}'),
        throwsA(
          isA<TailcatFailureException>().having(
            (e) => e.message,
            'message',
            allOf(contains('public_key'), isNot(contains('tcSECRET'))),
          ),
        ),
      );
      expect(
        () => JsonObject.decode('[1]', what: 'info'),
        throwsA(isA<TailcatFailureException>()),
      );
      expect(
        () => JsonObject.decode('{nope', what: 'info'),
        throwsA(isA<TailcatFailureException>()),
      );
    });
  });

  group('TailcatPath', () {
    test('is direct when it names an endpoint', () {
      final path = TailcatPath.fromJson(
        '{"latency":0.0125,"endpoint":"203.0.113.9:41641",'
        '"derp_region_id":0,"derp_region_code":""}',
      );
      expect(path.isDirect, isTrue);
      expect(path.endpoint, '203.0.113.9:41641');
      expect(path.latency, const Duration(microseconds: 12500));
      expect(path.derpRegionCode, isNull);
      expect('$path', contains('direct via 203.0.113.9:41641'));
    });

    test('is relayed when it names a region', () {
      final path = TailcatPath.fromJson(
        '{"latency":0.08,"endpoint":"","derp_region_id":2,'
        '"derp_region_code":"sfo"}',
      );
      expect(path.isDirect, isFalse);
      expect(path.endpoint, isNull);
      expect(path.derpRegionId, 2);
      expect(path.derpRegionCode, 'sfo');
      expect('$path', contains('relayed via sfo'));
    });
  });

  test('ports are checked before they reach a uint16', () {
    expect(checkPort(1), 1);
    expect(checkPort(65535), 65535);
    expect(checkPort(0, allowAny: true), 0);
    expect(() => checkPort(0), throwsRangeError);
    expect(() => checkPort(65536), throwsRangeError);
    expect(() => checkPort(-1, allowAny: true), throwsRangeError);
  });
}
