import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'bridge_protocol.dart';

/// Proxy that bridges the standard bridge-protocol WebSocket interface to
/// a web app running in Chrome via the Chrome DevTools Protocol (CDP).
///
/// Flow:
///   MCP server  --bridge WS-->  WebBridgeProxy  --CDP WS-->  Chrome
///
/// The proxy:
/// 1. Connects to Chrome's CDP WebSocket (typically port 9222).
/// 2. Injects `flutter-skill.js` into the page if not already loaded.
/// 3. Opens a bridge-protocol WebSocket server on [bridgeDefaultPort].
/// 4. Translates incoming JSON-RPC calls to `Runtime.evaluate` calls that
///    invoke `window.__FLUTTER_SKILL_CALL__()` in the browser.
/// 5. Handles `screenshot` directly via CDP `Page.captureScreenshot`.
class WebBridgeProxy {
  final int cdpPort;
  final int bridgePort;

  HttpServer? _server;
  WebSocket? _cdpWs;
  int _cdpId = 1;
  final Map<int, Completer<Map<String, dynamic>>> _cdpPending = {};

  WebBridgeProxy({
    this.cdpPort = 9222,
    this.bridgePort = bridgeDefaultPort,
  });

  /// Start the proxy. Connects to CDP and opens the bridge server.
  Future<void> start() async {
    // 1. Connect to Chrome CDP
    await _connectCdp();

    // 2. Inject the SDK script if needed
    await _injectSdkIfNeeded();

    // 3. Start the bridge WebSocket server
    _server = await HttpServer.bind('127.0.0.1', bridgePort);
    _server!.listen(_handleHttpRequest);
  }

  /// Stop the proxy and close all connections.
  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    try {
      await _cdpWs?.close();
    } catch (_) {}
    _cdpWs = null;
    _failAllCdpPending('Proxy stopped');
  }

  // ------------------------------------------------------------------
  // CDP connection
  // ------------------------------------------------------------------

  Future<void> _connectCdp() async {
    // Query CDP for the first inspectable page
    final client = HttpClient();
    final request = await client.get('127.0.0.1', cdpPort, '/json');
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    client.close();

    final pages = jsonDecode(body) as List<dynamic>;
    final page = pages.firstWhere(
      (p) => p['type'] == 'page',
      orElse: () =>
          throw Exception('No inspectable page found on CDP port $cdpPort'),
    );

    final wsUrl = page['webSocketDebuggerUrl'] as String;
    _cdpWs = await WebSocket.connect(wsUrl);
    _cdpWs!.listen(_onCdpMessage, onDone: _onCdpDisconnect);
  }

  void _onCdpDisconnect() {
    _cdpWs = null;
    _failAllCdpPending('CDP connection lost');
    // Auto-reconnect after a short delay
    Future.delayed(const Duration(seconds: 2), () async {
      try {
        await _connectCdp();
        await _injectSdkIfNeeded();
      } catch (_) {
        // Retry will happen on next bridge call via _cdpCall check
      }
    });
  }

  void _onCdpMessage(dynamic data) {
    try {
      final json = jsonDecode(data as String) as Map<String, dynamic>;
      final id = json['id'] as int?;
      if (id != null && _cdpPending.containsKey(id)) {
        final completer = _cdpPending.remove(id)!;
        if (json.containsKey('error')) {
          completer.completeError(Exception(jsonEncode(json['error'])));
        } else {
          completer.complete((json['result'] as Map<String, dynamic>?) ?? {});
        }
      }
    } catch (_) {}
  }

  Future<Map<String, dynamic>> _cdpCall(
      String method, Map<String, dynamic> params) async {
    if (_cdpWs == null) {
      // Attempt reconnection before failing
      try {
        await _connectCdp();
      } catch (e) {
        throw Exception('CDP not connected and reconnection failed: $e');
      }
    }
    final id = _cdpId++;
    final completer = Completer<Map<String, dynamic>>();
    _cdpPending[id] = completer;

    _cdpWs!.add(jsonEncode({
      'id': id,
      'method': method,
      'params': params,
    }));

    return completer.future.timeout(const Duration(seconds: 15), onTimeout: () {
      _cdpPending.remove(id);
      throw TimeoutException('CDP call "$method" timed out');
    });
  }

  void _failAllCdpPending(String reason) {
    for (final c in _cdpPending.values) {
      if (!c.isCompleted) c.completeError(Exception(reason));
    }
    _cdpPending.clear();
  }

  // ------------------------------------------------------------------
  // SDK injection
  // ------------------------------------------------------------------

  Future<void> _injectSdkIfNeeded() async {
    final checkResult = await _cdpCall('Runtime.evaluate', {
      'expression': 'typeof window.__FLUTTER_SKILL__ !== "undefined"',
      'returnByValue': true,
    });

    final alreadyLoaded = checkResult['result']?['value'] == true;
    if (alreadyLoaded) return;

    // Read the SDK script — try common locations
    String? sdkSource;
    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    final candidates = [
      // Relative to the flutter-skill package
      'sdks/web/flutter-skill.js',
      // npm global install
      if (home != null)
        '$home/.pub-cache/hosted/pub.dev/flutter_skill-latest/sdks/web/flutter-skill.js',
    ];

    for (final path in candidates) {
      final file = File(path);
      if (file.existsSync()) {
        sdkSource = file.readAsStringSync();
        break;
      }
    }

    // Fallback: use the inline minimal SDK loader
    sdkSource ??= _minimalSdkLoader;

    await _cdpCall('Runtime.evaluate', {
      'expression': sdkSource,
      'returnByValue': true,
    });
  }

  /// Minimal inline SDK that registers the bridge interface.
  /// Used as fallback if the full JS file can't be found.
  static const String _minimalSdkLoader = r'''
(function() {
  if (window.__FLUTTER_SKILL__) return;
  window.__FLUTTER_SKILL__ = { version: "inline", framework: "web" };
  window.__FLUTTER_SKILL_CALL__ = function(method, params) {
    return JSON.stringify({ error: "Full SDK not loaded. Include flutter-skill.js in your page." });
  };
})();
''';

  // ------------------------------------------------------------------
  // Bridge HTTP/WS server
  // ------------------------------------------------------------------

  Future<void> _handleHttpRequest(HttpRequest request) async {
    // Health-check endpoint
    if (request.uri.path == bridgeHealthPath) {
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'framework': 'web',
          'app_name': 'Web App (via CDP proxy)',
          'platform': 'web',
          'capabilities': [...bridgeCoreMethods, 'get_logs', 'clear_logs'],
          'sdk_version': bridgeProtocolVersion,
          'proxy': true,
        }));
      await request.response.close();
      return;
    }

    // WebSocket upgrade for JSON-RPC
    if (request.uri.path == '/ws' &&
        WebSocketTransformer.isUpgradeRequest(request)) {
      final ws = await WebSocketTransformer.upgrade(request);
      ws.listen((data) => _handleBridgeCall(ws, data as String));
      return;
    }

    // 404 for everything else
    request.response
      ..statusCode = HttpStatus.notFound
      ..write('Not found');
    await request.response.close();
  }

  Future<void> _handleBridgeCall(WebSocket ws, String raw) async {
    Map<String, dynamic> request;
    try {
      request = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      ws.add(jsonEncode({
        'jsonrpc': '2.0',
        'id': null,
        'error': {'code': -32700, 'message': 'Parse error'},
      }));
      return;
    }

    final id = request['id'];
    final method = request['method'] as String? ?? '';
    final params = request['params'] as Map<String, dynamic>? ?? {};

    try {
      Map<String, dynamic> result;

      if (method == 'screenshot') {
        // Handle screenshot directly via CDP
        result = await _handleScreenshot();
      } else if (method == 'initialize') {
        result = {
          'success': true,
          'framework': 'web',
          'protocol_version': bridgeProtocolVersion,
          'proxy': true,
        };
      } else {
        // Delegate to the in-page SDK
        result = await _evaluateInPage(method, params);
      }

      // Check if the in-page SDK returned an error (e.g. unknown method)
      if (result.containsKey('error') && result.length == 1) {
        ws.add(jsonEncode({
          'jsonrpc': '2.0',
          'id': id,
          'error': {'code': -32601, 'message': result['error'].toString()},
        }));
      } else {
        ws.add(jsonEncode({
          'jsonrpc': '2.0',
          'id': id,
          'result': result,
        }));
      }
    } catch (e) {
      ws.add(jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': -32000, 'message': e.toString()},
      }));
    }
  }

  Future<Map<String, dynamic>> _evaluateInPage(
      String method, Map<String, dynamic> params) async {
    // Base64-encode params to avoid JS injection/escaping issues
    final paramsB64 = base64.encode(utf8.encode(jsonEncode(params)));
    final expression =
        "JSON.parse(window.__FLUTTER_SKILL_CALL__('$method', JSON.parse(atob('$paramsB64'))))";

    final result = await _cdpCall('Runtime.evaluate', {
      'expression': expression,
      'returnByValue': true,
      'awaitPromise': true,
    });

    final value = result['result']?['value'];
    if (value is Map<String, dynamic>) return value;
    if (value is String) {
      return jsonDecode(value) as Map<String, dynamic>;
    }
    return {'raw': value};
  }

  Future<Map<String, dynamic>> _handleScreenshot() async {
    final result = await _cdpCall('Page.captureScreenshot', {
      'format': 'png',
    });
    return {'image': result['data']};
  }
}
