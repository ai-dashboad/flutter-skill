import 'dart:async';

import '../bridge/bridge_protocol.dart';
import '../bridge/web_bridge_listener.dart';
import 'bridge_driver.dart';

/// AppDriver that communicates with a browser-based SDK via a
/// [WebBridgeListener] (server-side WebSocket).
///
/// Extends [BridgeDriver] so all existing `client is BridgeDriver` checks
/// in the MCP server work transparently. The key difference is that
/// [connect] initializes from an already-accepted WebSocket (from the
/// listener) rather than connecting outward.
class WebBridgeDriver extends BridgeDriver {
  final WebBridgeListener _listener;

  WebBridgeDriver(this._listener)
      : super(
          'ws://127.0.0.1:${_listener.port ?? 18118}',
          BridgeServiceInfo(
            framework: 'web',
            appName: 'web-bridge-listener',
            platform: 'web',
            capabilities: bridgeCoreMethods.toSet(),
            sdkVersion: bridgeProtocolVersion,
            port: _listener.port ?? 18118,
            wsUri: 'ws://127.0.0.1:${_listener.port ?? 18118}',
          ),
        );

  @override
  String get frameworkName => 'web';

  @override
  bool get isConnected => _listener.hasClient;

  @override
  Future<void> connect() async {
    if (!_listener.hasClient) {
      throw Exception('No browser client connected to the bridge listener');
    }
    // Send initialize handshake via the listener
    await _listener.callMethod('initialize', {
      'protocol_version': bridgeProtocolVersion,
      'client': 'flutter-skill',
    });
    setConnected(true);
  }

  @override
  Future<void> disconnect() async {
    setConnected(false);
  }

  @override
  Future<Map<String, dynamic>> callMethod(String method,
      [Map<String, dynamic>? params]) {
    return _listener.callMethod(method, params);
  }
}
