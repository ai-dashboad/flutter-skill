import 'dart:convert';
import 'dart:io';

import 'package:async/async.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression tests for the JSON-RPC read loop.
///
/// A malformed frame from any client used to end the session: invalid UTF-8
/// raised a stream-level FormatException that no handler caught, and a
/// truncated JSON object produced no reply at all because the parse error was
/// dropped for having a null id. Both are denial-of-service primitives against
/// a stdio MCP server, so they are pinned here.
void main() {
  group('MCP server JSON-RPC framing', () {
    late Process server;
    late StreamQueue<String> responses;

    /// Longest a single well-formed request may take to come back. Generous so
    /// the suite stays reliable on a cold CI machine.
    const responseTimeout = Duration(seconds: 30);

    /// Under `flutter test` the running executable is `flutter_tester`, which
    /// cannot run a plain Dart entrypoint, so resolve the real Dart SDK.
    String dartExecutable() {
      final flutterRoot = Platform.environment['FLUTTER_ROOT'];
      if (flutterRoot != null && flutterRoot.isNotEmpty) {
        final sdkDart = File(
            '$flutterRoot/bin/cache/dart-sdk/bin/dart${Platform.isWindows ? '.exe' : ''}');
        if (sdkDart.existsSync()) return sdkDart.path;
      }
      return 'dart';
    }

    Future<void> send(List<int> bytes) async {
      server.stdin.add(bytes);
      await server.stdin.flush();
    }

    Future<void> sendJson(Object frame) => send(utf8.encode('${jsonEncode(frame)}\n'));

    Future<Map<String, dynamic>> nextResponse() async {
      final line = await responses.next.timeout(
        responseTimeout,
        onTimeout: () => throw StateError(
            'Server sent no response — it most likely died on the previous frame'),
      );
      return jsonDecode(line) as Map<String, dynamic>;
    }

    setUp(() async {
      // The server refuses to start while another instance holds the lock.
      final home = Platform.environment['HOME'] ??
          Platform.environment['USERPROFILE'] ??
          '/tmp';
      final lock = File('$home/.flutter_skill.lock');
      if (await lock.exists()) await lock.delete();

      server = await Process.start(
        dartExecutable(),
        ['run', 'bin/server.dart', 'server'],
      );
      server.stderr.drain<void>();
      responses = StreamQueue(server.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          // The child inherits the test runner's VM service flags and prints an
          // "observatory listening" banner on stdout. Keep only JSON-RPC frames.
          .where((line) => line.startsWith('{')));

      // Handshake first so a failure later is unambiguously caused by the
      // hostile frame under test and not by a server that never came up.
      await sendJson({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': <String, dynamic>{},
      });
      final hello = await nextResponse();
      expect(hello['id'], 1);
      expect(hello['result'], isNotNull);
    });

    tearDown(() async {
      await responses.cancel(immediate: true);
      server.kill();
      await server.exitCode;
    });

    /// Drives one hostile frame and asserts the server answers it and is still
    /// able to serve a normal request afterwards.
    Future<void> expectSurvives(
      List<int> hostileFrame, {
      required int expectedCode,
    }) async {
      await send(hostileFrame);

      final error = await nextResponse();
      expect(error['id'], isNull,
          reason: 'JSON-RPC 2.0 requires a null id when the id is unreadable');
      expect(error['error']['code'], expectedCode);

      await sendJson({
        'jsonrpc': '2.0',
        'id': 99,
        'method': 'tools/list',
        'params': <String, dynamic>{},
      });
      final after = await nextResponse();
      expect(after['id'], 99,
          reason: 'Server must still serve requests after a malformed frame');
    }

    test('should answer a parse error when a frame is truncated JSON', () async {
      await expectSurvives(utf8.encode('{"jsonrpc":"2.0","id":2,\n'),
          expectedCode: -32700);
    });

    test('should answer a parse error when a frame is not JSON at all', () async {
      await expectSurvives(utf8.encode('not json at all }{\n'),
          expectedCode: -32700);
    });

    test('should survive invalid UTF-8 bytes instead of exiting', () async {
      // A strict utf8.decoder throws on the stream rather than in the per-line
      // handler, which previously terminated the process.
      await expectSurvives([0xff, 0xfe, 0xfd, 0x0a], expectedCode: -32700);
    });

    test('should reject valid JSON that is not a request object', () async {
      await expectSurvives(utf8.encode('[1,2,3]\n'), expectedCode: -32600);
    });

    test('should stay silent for a notification carrying no id', () async {
      await sendJson({'jsonrpc': '2.0', 'method': 'notifications/initialized'});

      // Nothing should come back for the notification, so the next line read
      // must belong to the request sent after it.
      await sendJson({
        'jsonrpc': '2.0',
        'id': 50,
        'method': 'tools/list',
        'params': <String, dynamic>{},
      });
      final next = await nextResponse();
      expect(next['id'], 50,
          reason: 'A notification must not produce a response');
    });
  });
}
