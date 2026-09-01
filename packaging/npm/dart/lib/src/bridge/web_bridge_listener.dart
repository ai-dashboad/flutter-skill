import 'dart:io';
import 'dart:convert';
import 'dart:async';

import 'bridge_protocol.dart';

/// A WebSocket server that browser-based SDKs connect TO.
///
/// Unlike the normal bridge flow (MCP connects to SDK's WS server),
/// this listener starts a WS server that browser clients connect to,
/// since browsers cannot start WebSocket servers.
class WebBridgeListener {
  HttpServer? _server;
  WebSocket? _clientConnection;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  int _nextId = 1;
  int? _port;

  /// Callback invoked when a browser client connects.
  void Function(WebSocket ws)? onClientConnected;

  /// Callback invoked when a browser client disconnects.
  void Function()? onClientDisconnected;

  int? get port => _port;

  Future<void> start(int port) async {
    _port = port;
    _server = await HttpServer.bind('127.0.0.1', port);
    _server!.listen((request) async {
      if (WebSocketTransformer.isUpgradeRequest(request)) {
        final ws = await WebSocketTransformer.upgrade(request);
        _handleClient(ws);
      } else if (request.uri.path == '/' ||
          request.uri.path == '/health' ||
          request.uri.path == bridgeHealthPath) {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'status': 'ok',
          'platform': 'web',
          'framework': 'web',
          'app_name': 'web-bridge-listener',
          'sdk_version': bridgeProtocolVersion,
          'ws_port': port,
          'ws_uri': 'ws://127.0.0.1:$port',
          'capabilities': bridgeCoreMethods,
        }));
        await request.response.close();
      } else {
        request.response.statusCode = 404;
        await request.response.close();
      }
    });
  }

  void _handleClient(WebSocket ws) {
    // Replace existing client reference (don't close — may trigger SDK reconnect loop)
    _clientConnection = ws;

    ws.listen(
      (data) {
        try {
          final msg = jsonDecode(data as String) as Map<String, dynamic>;
          final id = msg['id'];
          if (id != null && _pending.containsKey(id)) {
            if (msg.containsKey('error')) {
              final err = msg['error'] as Map<String, dynamic>;
              _pending[id]!.completeError(RpcError(
                code: err['code'] as int? ?? -1,
                message: err['message'] as String? ?? 'Unknown error',
                data: err['data'],
              ));
            } else {
              _pending[id]!
                  .complete((msg['result'] as Map<String, dynamic>?) ?? {});
            }
            _pending.remove(id);
          }
        } catch (_) {
          // Malformed message
        }
      },
      onDone: () {
        _clientConnection = null;
        _failAllPending('Browser client disconnected');
        onClientDisconnected?.call();
      },
      onError: (_) {
        _clientConnection = null;
        _failAllPending('Browser client connection error');
        onClientDisconnected?.call();
      },
    );

    // Notify after ws.listen is set up so responses can be received
    onClientConnected?.call(ws);
  }

  bool get hasClient =>
      _clientConnection != null &&
      _clientConnection!.readyState == WebSocket.open;

  Future<Map<String, dynamic>> callMethod(String method,
      [Map<String, dynamic>? params]) async {
    if (!hasClient) throw Exception('No browser client connected');
    final id = _nextId++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    _clientConnection!.add(buildRpcRequestWithId(id, method, params));
    return completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        _pending.remove(id);
        throw TimeoutException(
            'Bridge call "$method" timed out', const Duration(seconds: 30));
      },
    );
  }

  void _failAllPending(String reason) {
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(Exception('WebBridgeListener: $reason'));
      }
    }
    _pending.clear();
  }

  Future<void> stop() async {
    _failAllPending('Listener stopping');
    try {
      await _clientConnection?.close();
    } catch (_) {}
    _clientConnection = null;
    await _server?.close();
    _server = null;
    _port = null;
  }
}
