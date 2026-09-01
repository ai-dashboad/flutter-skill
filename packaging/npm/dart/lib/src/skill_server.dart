import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'drivers/app_driver.dart';
import 'drivers/flutter_driver.dart';
import 'server_registry.dart';

/// A lightweight JSON-RPC 2.0 server over raw TCP (newline-delimited JSON)
/// that exposes AppDriver capabilities to local CLI clients.
///
/// Lifecycle:
///   1. Call [start] — binds a random free TCP port, registers in [ServerRegistry].
///   2. Clients connect and send newline-delimited JSON-RPC 2.0 requests.
///   3. Call [stop] — closes all connections, unregisters from [ServerRegistry].
class SkillServer {
  final String id;
  final AppDriver driver;
  final String projectPath;
  final String deviceId;

  ServerSocket? _tcpServer;
  ServerSocket? _unixServer;
  int? _port;
  final List<Socket> _connections = [];
  bool _stopped = false;

  final _shutdownController = StreamController<void>.broadcast();

  /// Stream that emits when the server has been asked to shut down via the
  /// `shutdown` JSON-RPC method. Callers (e.g. [runConnect]) can listen to
  /// this stream to perform orderly cleanup.
  Stream<void> get onShutdownRequested => _shutdownController.stream;

  SkillServer({
    required this.id,
    required this.driver,
    this.projectPath = '',
    this.deviceId = '',
  });

  int get port => _port ?? 0;

  /// Start listening. Binds a random free TCP port and registers in the registry.
  Future<void> start() async {
    _tcpServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _port = _tcpServer!.port;

    _tcpServer!.listen(_handleConnection);

    // On Unix, also bind a Unix domain socket for lower-latency local IPC.
    final sockPath = ServerRegistry.unixSocketPath(id);
    if (sockPath != null) {
      try {
        // Remove stale socket file if present.
        final sockFile = File(sockPath);
        if (await sockFile.exists()) await sockFile.delete();

        _unixServer = await ServerSocket.bind(
          InternetAddress(sockPath, type: InternetAddressType.unix),
          0,
        );
        _unixServer!.listen(_handleConnection);
      } catch (_) {
        // Unix socket is optional — silently ignore failures.
      }
    }

    final entry = ServerEntry(
      id: id,
      port: _port!,
      pid: pid,
      projectPath: projectPath,
      deviceId: deviceId,
      vmServiceUri: _vmServiceUri(),
      startedAt: DateTime.now(),
    );
    await ServerRegistry.register(entry);
  }

  /// Stop the server and unregister from the registry.
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    for (final conn in List<Socket>.from(_connections)) {
      await conn.close().catchError((_) {});
    }
    _connections.clear();
    await _tcpServer?.close();
    await _unixServer?.close();
    await ServerRegistry.unregister(id);
    if (!_shutdownController.isClosed) {
      await _shutdownController.close();
    }
  }

  // ---------------------------------------------------------------------------
  // Connection handling
  // ---------------------------------------------------------------------------

  void _handleConnection(Socket socket) {
    _connections.add(socket);

    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) => _handleLine(socket, line),
          onDone: () => _connections.remove(socket),
          onError: (_) => _connections.remove(socket),
          cancelOnError: false,
        );
  }

  Future<void> _handleLine(Socket socket, String line) async {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return;

    Map<String, dynamic> request;
    try {
      request = jsonDecode(trimmed) as Map<String, dynamic>;
    } catch (e) {
      _sendError(socket, null, -32700, 'Parse error: $e');
      return;
    }

    final requestId = request['id'];
    final method = request['method'] as String?;
    final params = (request['params'] as Map<String, dynamic>?) ?? {};

    if (method == null) {
      _sendError(socket, requestId, -32600, 'Invalid Request: missing method');
      return;
    }

    try {
      final result = await _dispatch(method, params);
      _sendResult(socket, requestId, result);
    } catch (e) {
      _sendError(socket, requestId, -32000, e.toString());
    }
  }

  // ---------------------------------------------------------------------------
  // Method dispatch — mirrors the MCP tool set
  //
  // Phase 1 implemented methods:
  //   tap, enter_text, swipe, inspect, screenshot, get_logs, clear_logs,
  //   hot_reload, hot_restart, scroll_to, ping, shutdown
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>> _dispatch(
      String method, Map<String, dynamic> params) async {
    switch (method) {
      case 'tap':
        final result = await driver.tap(
          key: params['key'] as String?,
          text: params['text'] as String?,
          ref: params['ref'] as String?,
        );
        return result;

      case 'enter_text':
        final result = await driver.enterText(
          params['key'] as String?,
          params['text'] as String? ?? '',
          ref: params['ref'] as String?,
        );
        return result;

      case 'swipe':
        final success = await driver.swipe(
          direction: params['direction'] as String? ?? 'up',
          distance: (params['distance'] as num?)?.toDouble() ?? 300,
          key: params['key'] as String?,
        );
        return {'success': success};

      case 'inspect':
        final elements = await driver.getInteractiveElements(
          includePositions: (params['includePositions'] as bool?) ?? true,
        );
        return {'elements': elements};

      case 'screenshot':
        final image = await driver.takeScreenshot(
          quality: (params['quality'] as num?)?.toDouble() ?? 1.0,
          maxWidth: params['maxWidth'] as int?,
        );
        if (image == null) {
          throw Exception(
              'Screenshot returned null — app may not be visible');
        }
        return {'image': image};

      case 'get_logs':
        final logs = await driver.getLogs();
        return {'logs': logs};

      case 'clear_logs':
        await driver.clearLogs();
        return {'success': true};

      case 'hot_reload':
        await driver.hotReload();
        return {'success': true};

      case 'hot_restart':
        if (driver is FlutterSkillClient) {
          try {
            await (driver as FlutterSkillClient).hotRestart();
            return {'success': true};
          } catch (e) {
            // hotRestart failed — fall back to hotReload with warning.
            await driver.hotReload();
            return {
              'success': true,
              'warning':
                  'hotRestart failed ($e); performed hotReload instead',
            };
          }
        }
        await driver.hotReload();
        return {
          'success': true,
          'warning':
              'hotRestart not supported by this driver; performed hotReload',
        };

      case 'scroll_to':
        final scrollKey = params['key'] as String?;
        final scrollText = params['text'] as String?;
        try {
          // FlutterSkillClient has scrollTo; other drivers fall back to swipe.
          final fsc = driver as FlutterSkillClient;
          final result = await fsc.scrollTo(key: scrollKey, text: scrollText);
          return result;
        } catch (_) {
          final success = await driver.swipe(
            direction: 'down',
            distance: 300,
            key: scrollKey,
          );
          return {'success': success};
        }

      case 'assert_visible':
        // Check if element is present in interactive elements list.
        final assertVisibleKey =
            params['key'] as String? ?? params['text'] as String?;
        final assertVisibleElements =
            await driver.getInteractiveElements(includePositions: false);
        final assertVisibleFound =
            assertVisibleElements.any((e) => _elementMatches(e, assertVisibleKey));
        if (!assertVisibleFound) {
          throw Exception('Element not found: $assertVisibleKey');
        }
        return {'success': true, 'visible': true};

      case 'assert_gone':
        final assertGoneKey =
            params['key'] as String? ?? params['text'] as String?;
        final assertGoneElements =
            await driver.getInteractiveElements(includePositions: false);
        final assertGoneFound =
            assertGoneElements.any((e) => _elementMatches(e, assertGoneKey));
        if (assertGoneFound) {
          throw Exception('Element still present: $assertGoneKey');
        }
        return {'success': true, 'gone': true};

      case 'wait_for_element':
        final waitKey =
            params['key'] as String? ?? params['text'] as String?;
        final timeoutMs = (params['timeout'] as num?)?.toInt() ?? 5000;
        final deadline =
            DateTime.now().add(Duration(milliseconds: timeoutMs));
        while (DateTime.now().isBefore(deadline)) {
          final waitElements =
              await driver.getInteractiveElements(includePositions: false);
          if (waitElements.any((e) => _elementMatches(e, waitKey))) {
            return {'success': true};
          }
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        throw Exception('Timeout waiting for element: $waitKey');

      case 'get_text':
        // Get visible text of a specific element or entire screen.
        final getTextKey = params['key'] as String?;
        if (getTextKey == null) {
          final getTextElements =
              await driver.getInteractiveElements(includePositions: false);
          final texts = getTextElements
              .whereType<Map>()
              .map((e) => e['text']?.toString() ?? '')
              .where((t) => t.isNotEmpty)
              .toList();
          return {'texts': texts};
        }
        final getTextAllElements =
            await driver.getInteractiveElements(includePositions: false);
        final getTextEl = getTextAllElements.whereType<Map>().firstWhere(
              (e) => _elementMatches(e, getTextKey),
              orElse: () => {},
            );
        return {'text': getTextEl['text']?.toString() ?? ''};

      case 'find_element':
        final findKey =
            params['key'] as String? ?? params['text'] as String?;
        final findElements =
            await driver.getInteractiveElements(includePositions: true);
        final findEl = findElements.whereType<Map>().firstWhere(
              (e) => _elementMatches(e, findKey),
              orElse: () => {},
            );
        if (findEl.isEmpty) throw Exception('Element not found: $findKey');
        return Map<String, dynamic>.from(findEl);

      case 'go_back':
        try {
          final d = driver as FlutterSkillClient;
          await d.goBack();
        } catch (_) {
          // Driver doesn't support goBack — no-op (web navigation not available).
        }
        return {'success': true};

      case 'shutdown':
        // Signal listeners (e.g. runConnect) to perform orderly shutdown after
        // the response is delivered to the client.
        Future.microtask(() => _shutdownController.add(null));
        return {'success': true};

      case 'ping':
        return {'pong': true, 'server': id};

      default:
        throw Exception('Method not found: $method');
    }
  }

  // ---------------------------------------------------------------------------
  // JSON-RPC helpers
  // ---------------------------------------------------------------------------

  void _sendResult(Socket socket, dynamic requestId, Map<String, dynamic> result) {
    final response = jsonEncode({
      'jsonrpc': '2.0',
      'id': requestId,
      'result': result,
    });
    try {
      socket.writeln(response);
    } catch (_) {
      _connections.remove(socket);
      socket.destroy();
    }
  }

  void _sendError(Socket socket, dynamic requestId, int code, String message) {
    final response = jsonEncode({
      'jsonrpc': '2.0',
      'id': requestId,
      'error': {'code': code, 'message': message},
    });
    try {
      socket.writeln(response);
    } catch (_) {
      _connections.remove(socket);
      socket.destroy();
    }
  }

  String _vmServiceUri() {
    if (driver is FlutterSkillClient) {
      return (driver as FlutterSkillClient).vmServiceUri;
    }
    return '';
  }

  // ---------------------------------------------------------------------------
  // Element matching helper
  // ---------------------------------------------------------------------------

  /// Returns true if [e] is a Map that matches [query] by key, text, or ref.
  static bool _elementMatches(dynamic e, String? query) {
    if (e is! Map || query == null) return false;
    return e['key'] == query || e['text'] == query || e['ref'] == query;
  }
}
