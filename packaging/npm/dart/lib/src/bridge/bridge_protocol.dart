import 'dart:convert';

/// Bridge Protocol — enables communication with any framework's in-app SDK.
///
/// Each target app (React Native, web, native iOS/Android, etc.) installs a
/// lightweight SDK that starts a bridge service. The testing tool connects
/// over the network using JSON-RPC 2.0 over WebSocket.

/// Protocol version. SDKs must return this in their health-check response.
const String bridgeProtocolVersion = '1.0';

/// Default port for bridge services.
const int bridgeDefaultPort = 18118;

/// Port range scanned when looking for bridge-enabled apps.
const int bridgePortRangeStart = 18118;
const int bridgePortRangeEnd = 18128;

/// Health-check endpoint path. A GET request here returns [BridgeServiceInfo].
const String bridgeHealthPath = '/.flutter-skill';

/// Core methods every bridge SDK MUST implement.
const List<String> bridgeCoreMethods = [
  'initialize',
  'screenshot',
  'inspect',
  'tap',
  'enter_text',
  'swipe',
  'scroll',
  'find_element',
  'get_text',
  'wait_for_element',
];

/// Extended methods that SDKs MAY implement (advertised via capabilities).
const List<String> bridgeExtendedMethods = [
  'long_press',
  'double_tap',
  'drag',
  'get_state',
  'get_logs',
  'clear_logs',
  'hot_reload',
  'get_route',
  'go_back',
];

/// Information about a discovered bridge service.
class BridgeServiceInfo {
  /// Framework name (e.g. "react-native", "web", "swiftui").
  final String framework;

  /// Application name as reported by the SDK.
  final String appName;

  /// Platform (e.g. "ios", "android", "web", "macos").
  final String platform;

  /// Set of capabilities the SDK advertises (method names).
  final Set<String> capabilities;

  /// SDK version string.
  final String sdkVersion;

  /// Port the bridge service is listening on.
  final int port;

  /// Full WebSocket URI for JSON-RPC communication.
  final String wsUri;

  BridgeServiceInfo({
    required this.framework,
    required this.appName,
    required this.platform,
    required this.capabilities,
    required this.sdkVersion,
    required this.port,
    required this.wsUri,
  });

  /// Parse from the JSON returned by the health-check endpoint.
  factory BridgeServiceInfo.fromHealthCheck(
      Map<String, dynamic> json, int port) {
    final caps = (json['capabilities'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toSet() ??
        {};
    return BridgeServiceInfo(
      framework: json['framework'] as String? ?? 'unknown',
      appName: json['app_name'] as String? ?? 'unknown',
      platform: json['platform'] as String? ?? 'unknown',
      capabilities: caps,
      sdkVersion: json['sdk_version'] as String? ?? '0.0.0',
      port: port,
      wsUri: json['ws_uri'] as String? ??
          'ws://127.0.0.1:${json['ws_port'] ?? port}/ws',
    );
  }

  Map<String, dynamic> toJson() => {
        'framework': framework,
        'app_name': appName,
        'platform': platform,
        'capabilities': capabilities.toList(),
        'sdk_version': sdkVersion,
        'port': port,
        'ws_uri': wsUri,
      };

  @override
  String toString() => '$framework app "$appName" on $platform (port $port)';
}

// ---------------------------------------------------------------------------
// JSON-RPC 2.0 message helpers
// ---------------------------------------------------------------------------

int _nextId = 1;

/// Build a JSON-RPC 2.0 request string.
String buildRpcRequest(String method, [Map<String, dynamic>? params]) {
  final id = _nextId++;
  return jsonEncode({
    'jsonrpc': '2.0',
    'id': id,
    'method': method,
    if (params != null) 'params': params,
  });
}

/// Build a JSON-RPC 2.0 request with a specific id.
String buildRpcRequestWithId(int id, String method,
    [Map<String, dynamic>? params]) {
  return jsonEncode({
    'jsonrpc': '2.0',
    'id': id,
    'method': method,
    if (params != null) 'params': params,
  });
}

/// Parse a JSON-RPC 2.0 response. Returns the `result` field on success
/// or throws on error.
Map<String, dynamic> parseRpcResponse(String raw) {
  final json = jsonDecode(raw) as Map<String, dynamic>;
  if (json.containsKey('error')) {
    final err = json['error'] as Map<String, dynamic>;
    throw RpcError(
      code: err['code'] as int? ?? -1,
      message: err['message'] as String? ?? 'Unknown error',
      data: err['data'],
    );
  }
  return (json['result'] as Map<String, dynamic>?) ?? {};
}

/// Extract the `id` from a JSON-RPC message.
int? parseRpcId(String raw) {
  final json = jsonDecode(raw) as Map<String, dynamic>;
  return json['id'] as int?;
}

/// JSON-RPC error.
class RpcError implements Exception {
  final int code;
  final String message;
  final dynamic data;

  RpcError({required this.code, required this.message, this.data});

  @override
  String toString() => 'RpcError($code): $message';
}
