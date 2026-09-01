import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../bridge/bridge_protocol.dart';
import 'app_driver.dart';

/// AppDriver that communicates with an in-app bridge SDK over WebSocket
/// using JSON-RPC 2.0.
///
/// Works with any framework (React Native, web, native, etc.) as long as
/// the target app includes the bridge SDK.
class BridgeDriver implements AppDriver {
  final String _wsUri;
  final BridgeServiceInfo info;

  WebSocket? _ws;
  bool _connected = false;
  bool _reconnecting = false;

  /// Pending RPC calls keyed by request id.
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  int _nextId = 1;
  Timer? _pingTimer;

  /// Set WebSocket and connection state directly (used by WebBridgeDriver).
  void setWebSocket(WebSocket ws) {
    _ws = ws;
    _connected = true;
    _ws!.listen(
      _onMessage,
      onDone: _onDisconnect,
      onError: (_) => _onDisconnect(),
      cancelOnError: false,
    );
    _startPingTimer();
  }

  /// Mark as connected without a WebSocket (for subclasses).
  void setConnected(bool value) => _connected = value;

  BridgeDriver(this._wsUri, this.info);

  /// Create from a [BridgeServiceInfo] returned by discovery.
  factory BridgeDriver.fromInfo(BridgeServiceInfo info) {
    return BridgeDriver(info.wsUri, info);
  }

  // ------------------------------------------------------------------
  // AppDriver interface
  // ------------------------------------------------------------------

  @override
  String get frameworkName => info.framework;

  @override
  bool get isConnected => _connected;

  @override
  Future<void> connect() async {
    try {
      _ws = await WebSocket.connect(_wsUri).timeout(const Duration(seconds: 5));
      _connected = true;

      _ws!.listen(
        _onMessage,
        onDone: _onDisconnect,
        onError: (_) => _onDisconnect(),
        cancelOnError: false,
      );

      // Start ping keepalive (every 15s)
      _startPingTimer();

      // Send initialize handshake
      await callMethod('initialize', {
        'protocol_version': bridgeProtocolVersion,
        'client': 'flutter-skill',
      });
    } catch (e) {
      _connected = false;
      _ws = null;
      throw Exception('Failed to connect to bridge at $_wsUri: $e');
    }
  }

  @override
  Future<void> disconnect() async {
    _connected = false;
    _pingTimer?.cancel();
    _pingTimer = null;
    _failAllPending('Disconnected');
    try {
      await _ws?.close();
    } catch (_) {}
    _ws = null;
  }

  void _startPingTimer() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      try {
        _ws?.add('ping');
      } catch (_) {
        _onDisconnect();
      }
    });
  }

  @override
  Future<Map<String, dynamic>> tap(
      {String? key, String? text, String? ref}) async {
    return callMethod('tap', {
      if (key != null) 'key': key,
      if (text != null) 'text': text,
      if (ref != null) 'ref': ref,
    });
  }

  @override
  Future<Map<String, dynamic>> enterText(String? key, String text,
      {String? ref}) async {
    return callMethod('enter_text', {
      if (key != null) 'key': key,
      'text': text,
      if (ref != null) 'ref': ref,
    });
  }

  @override
  Future<bool> swipe(
      {required String direction, double distance = 300, String? key}) async {
    final result = await callMethod('swipe', {
      'direction': direction,
      'distance': distance,
      if (key != null) 'key': key,
    });
    return result['success'] == true;
  }

  @override
  Future<List<dynamic>> getInteractiveElements(
      {bool includePositions = true}) async {
    final result = await callMethod('inspect', {
      'includePositions': includePositions,
    });
    return (result['elements'] as List<dynamic>?) ?? [];
  }

  @override
  Future<Map<String, dynamic>> getInteractiveElementsStructured() async {
    final result = await callMethod('inspect_interactive', {});
    return result.cast<String, dynamic>();
  }

  @override
  Future<String?> takeScreenshot({double quality = 1.0, int? maxWidth}) async {
    final result = await callMethod('screenshot', {
      'quality': quality,
      if (maxWidth != null) 'maxWidth': maxWidth,
    });
    // Some SDKs (e.g. React Native) return _needs_native flag when
    // in-app screenshot is not available; caller should fall back to
    // native_screenshot in that case.
    if (result['_needs_native'] == true) return null;
    return result['image'] as String?;
  }

  @override
  Future<List<String>> getLogs() async {
    final result = await callMethod('get_logs');
    return (result['logs'] as List?)?.cast<String>() ?? [];
  }

  @override
  Future<void> clearLogs() async {
    await callMethod('clear_logs');
  }

  @override
  Future<void> hotReload() async {
    await callMethod('hot_reload');
  }

  // ------------------------------------------------------------------
  // Extended bridge methods (may not be supported by all SDKs)
  // ------------------------------------------------------------------

  Future<Map<String, dynamic>> findElement(
      {String? key, String? text, String? selector}) async {
    return callMethod('find_element', {
      if (key != null) 'key': key,
      if (text != null) 'text': text,
      if (selector != null) 'selector': selector,
    });
  }

  Future<String?> getText({String? key, String? selector}) async {
    final result = await callMethod('get_text', {
      if (key != null) 'key': key,
      if (selector != null) 'selector': selector,
    });
    return result['text'] as String?;
  }

  Future<bool> waitForElement(
      {String? key, String? text, int timeout = 5000}) async {
    final result = await callMethod('wait_for_element', {
      if (key != null) 'key': key,
      if (text != null) 'text': text,
      'timeout': timeout,
    });
    return result['found'] == true;
  }

  Future<Map<String, dynamic>> scroll(
      {String? direction, double? distance, String? key}) async {
    return callMethod('scroll', {
      if (direction != null) 'direction': direction,
      if (distance != null) 'distance': distance,
      if (key != null) 'key': key,
    });
  }

  Future<bool> longPress(
      {String? key, String? text, int duration = 500}) async {
    final result = await callMethod('long_press', {
      if (key != null) 'key': key,
      if (text != null) 'text': text,
      'duration': duration,
    });
    return result['success'] == true;
  }

  Future<bool> doubleTap({String? key, String? text}) async {
    final result = await callMethod('double_tap', {
      if (key != null) 'key': key,
      if (text != null) 'text': text,
    });
    return result['success'] == true;
  }

  Future<String?> getRoute() async {
    final result = await callMethod('get_route');
    return result['route'] as String?;
  }

  Future<bool> goBack() async {
    final result = await callMethod('go_back');
    return result['success'] == true;
  }

  /// Check whether a specific method is supported by this SDK.
  bool hasCapability(String method) => info.capabilities.contains(method);

  // ------------------------------------------------------------------
  // Internal RPC plumbing
  // ------------------------------------------------------------------

  /// Public raw method call for tools that need direct bridge access (e.g. eval)
  /// Subclasses (e.g. WebBridgeDriver) override this to route through
  /// a different transport. All internal methods call [callMethod] so the
  /// override is always respected.
  Future<Map<String, dynamic>> callMethod(String method,
      [Map<String, dynamic>? params]) async {
    if (_ws == null || !_connected) {
      // Attempt one reconnect
      if (!_reconnecting && await _reconnect()) {
        return callMethod(method, params);
      }
      throw Exception('Not connected to bridge at $_wsUri');
    }

    final id = _nextId++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;

    final request = buildRpcRequestWithId(id, method, params);
    _ws!.add(request);

    // Timeout after 30 seconds
    return completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        _pending.remove(id);
        throw TimeoutException(
            'Bridge call "$method" timed out', const Duration(seconds: 30));
      },
    );
  }

  void _onMessage(dynamic data) {
    try {
      final str = data as String;
      // Ignore pong keepalive responses
      if (str == 'pong') return;
      final json = jsonDecode(str) as Map<String, dynamic>;
      final id = json['id'] as int?;
      if (id != null && _pending.containsKey(id)) {
        final completer = _pending.remove(id)!;
        if (json.containsKey('error')) {
          final err = json['error'] as Map<String, dynamic>;
          completer.completeError(RpcError(
            code: err['code'] as int? ?? -1,
            message: err['message'] as String? ?? 'Unknown error',
            data: err['data'],
          ));
        } else {
          completer.complete((json['result'] as Map<String, dynamic>?) ?? {});
        }
      }
      // Ignore notifications (no id) for now
    } catch (e) {
      // Malformed message — ignore
    }
  }

  void _onDisconnect() {
    _connected = false;
    _failAllPending('Connection lost');
  }

  void _failAllPending(String reason) {
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(Exception('Bridge: $reason'));
      }
    }
    _pending.clear();
  }

  Future<bool> _reconnect() async {
    if (_reconnecting) return false;
    _reconnecting = true;
    try {
      await disconnect();
      _ws = await WebSocket.connect(_wsUri).timeout(const Duration(seconds: 5));
      _connected = true;
      _ws!.listen(
        _onMessage,
        onDone: _onDisconnect,
        onError: (_) => _onDisconnect(),
        cancelOnError: false,
      );
      // Re-send initialize handshake after reconnect
      try {
        await callMethod('initialize', {
          'protocol_version': bridgeProtocolVersion,
          'client': 'flutter-skill',
        });
      } catch (_) {
        // Some SDKs may not require re-init
      }
      return true;
    } catch (_) {
      _connected = false;
      return false;
    } finally {
      _reconnecting = false;
    }
  }

  // --------------- AppMCP Tool Discovery & Calling ---------------

  /// Discover tools from the app — combines SDK-registered tools + auto-discovered UI elements.
  /// No app changes needed: buttons → tap tools, inputs → fill tools, toggles → toggle tools.
  Future<Map<String, dynamic>> discoverTools() async {
    final tools = <Map<String, dynamic>>[];

    // 1. SDK-registered tools (if app opted in)
    try {
      final registered = await callMethod('get_registered_tools');
      final regTools = registered['tools'] as List<dynamic>? ?? [];
      for (final t in regTools) {
        if (t is Map) tools.add(Map<String, dynamic>.from(t));
      }
    } catch (_) {}

    // 2. Auto-discover from UI elements (zero-config)
    try {
      final elements = await callMethod('inspect_interactive');
      final items = elements['elements'] as List<dynamic>? ?? [];
      for (final el in items) {
        if (el is! Map) continue;
        final role = el['role'] as String? ?? '';
        final ref = el['ref'] as String? ?? '';
        final text = el['text'] as String? ?? el['label'] as String? ?? '';
        final id = el['id'] as String? ?? '';
        final type = el['type'] as String? ?? '';

        if (ref.isEmpty && id.isEmpty) continue;

        switch (role) {
          case 'button':
          case 'link':
            tools.add({
              'name': 'tap_${_sanitizeName(text.isNotEmpty ? text : id)}',
              'description': 'Tap ${role}: ${text.isNotEmpty ? text : id}',
              'params': {},
              'source': 'auto-ui',
              'action': 'tap',
              'ref': ref,
              'element_id': id,
            });
            break;
          case 'input':
            tools.add({
              'name': 'fill_${_sanitizeName(text.isNotEmpty ? text : id)}',
              'description': 'Enter text into: ${text.isNotEmpty ? text : id}',
              'params': {
                'text': {
                  'type': 'string',
                  'required': true,
                  'description': 'Text to enter'
                }
              },
              'source': 'auto-ui',
              'action': 'enter_text',
              'ref': ref,
              'element_id': id,
              'input_type': type,
            });
            break;
          case 'toggle':
            tools.add({
              'name': 'toggle_${_sanitizeName(text.isNotEmpty ? text : id)}',
              'description': 'Toggle: ${text.isNotEmpty ? text : id}',
              'params': {},
              'source': 'auto-ui',
              'action': 'tap',
              'ref': ref,
              'element_id': id,
            });
            break;
          case 'slider':
            tools.add({
              'name': 'set_${_sanitizeName(text.isNotEmpty ? text : id)}',
              'description': 'Set slider: ${text.isNotEmpty ? text : id}',
              'params': {
                'value': {
                  'type': 'number',
                  'required': true,
                  'description': 'Slider value'
                }
              },
              'source': 'auto-ui',
              'action': 'set_slider',
              'ref': ref,
              'element_id': id,
            });
            break;
          case 'select':
            tools.add({
              'name': 'select_${_sanitizeName(text.isNotEmpty ? text : id)}',
              'description': 'Select option in: ${text.isNotEmpty ? text : id}',
              'params': {
                'value': {
                  'type': 'string',
                  'required': true,
                  'description': 'Option to select'
                }
              },
              'source': 'auto-ui',
              'action': 'select',
              'ref': ref,
              'element_id': id,
            });
            break;
        }
      }
    } catch (_) {}

    return {'tools': tools, 'count': tools.length};
  }

  /// Call a tool — either SDK-registered or auto-discovered from UI.
  Future<Map<String, dynamic>> callTool(
      String name, Map<String, dynamic> args) async {
    // First try SDK-registered tool
    try {
      return await callMethod('call_tool', {'name': name, 'args': args});
    } catch (_) {}

    // Fall back to auto-UI tool: re-discover and execute action
    final discovered = await discoverTools();
    final tools = discovered['tools'] as List<dynamic>? ?? [];
    final tool = tools.cast<Map<String, dynamic>?>().firstWhere(
          (t) => t!['name'] == name,
          orElse: () => null,
        );
    if (tool == null) throw Exception('Tool not found: $name');

    final action = tool['action'] as String? ?? '';
    final ref = tool['ref'] as String? ?? '';

    switch (action) {
      case 'tap':
        return await callMethod('tap', {'ref': ref});
      case 'enter_text':
        return await callMethod('enter_text', {
          'ref': ref,
          'text': args['text'] ?? '',
        });
      case 'set_slider':
        // Tap the slider, then try to set value
        return await callMethod('tap', {'ref': ref});
      case 'select':
        return await callMethod('tap', {'ref': ref});
      default:
        throw Exception('Unknown action for tool: $name');
    }
  }

  static String _sanitizeName(String input) {
    return input
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_]'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
  }
}
