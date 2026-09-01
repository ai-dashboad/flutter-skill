import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// DTD Service Discovery Tool
///
/// Uses the DTD protocol (enabled by default in Flutter 3.x) to discover VM Service URI
class DtdServiceDiscovery {
  /// Discover VM Service through DTD scanning
  ///
  /// Strategy:
  /// 1. Scan port range for DTD services
  /// 2. Connect to DTD and query VM Service URI
  /// 3. Return available VM Service URI
  static Future<DiscoveryResult> discover({
    int portStart = 50000,
    int portEnd = 60000,
  }) async {
    print('🔍 Scanning DTD services (port range: $portStart-$portEnd)...');

    // 1. Scan DTD ports
    final dtdUris = await _scanDtdPorts(
      portStart: portStart,
      portEnd: portEnd,
    );

    if (dtdUris.isEmpty) {
      return DiscoveryResult(
        success: false,
        message: 'No running Flutter app found (DTD service)',
      );
    }

    print('✅ Found ${dtdUris.length} DTD service(s)');

    // 2. Try to get VM Service URI from each DTD
    for (final dtdUri in dtdUris) {
      print('   Checking DTD: $dtdUri');

      final vmUri = await _queryVmServiceFromDtd(dtdUri);

      if (vmUri != null) {
        print('   ✅ Found VM Service: $vmUri');
        return DiscoveryResult(
          success: true,
          vmServiceUri: vmUri,
          dtdUri: dtdUri,
          discoveryMethod: 'dtd_query',
          message: 'VM Service discovered via DTD',
        );
      } else {
        print('   ⚠️  This DTD has no VM Service enabled');
      }
    }

    // 3. Found DTD but no VM Service
    return DiscoveryResult(
      success: false,
      dtdUri: dtdUris.first,
      discoveryMethod: 'dtd_only',
      message: 'Only found DTD service, VM Service not enabled',
      suggestions: [
        'DTD protocol is connected, but VM Service is not started',
        'To enable full functionality, restart the app:',
        'flutter run --vm-service-port=50000',
      ],
    );
  }

  /// Scan port range for DTD services
  static Future<List<String>> _scanDtdPorts({
    required int portStart,
    required int portEnd,
  }) async {
    final dtdUris = <String>[];
    final futures = <Future>[];

    for (var port = portStart; port <= portEnd; port++) {
      futures.add(_probeDtdPort(port).then((uri) {
        if (uri != null) {
          dtdUris.add(uri);
        }
      }));
    }

    await Future.wait(futures);
    return dtdUris;
  }

  /// Probe a single port to check if it's a DTD service
  static Future<String?> _probeDtdPort(int port) async {
    try {
      // Try to connect to the port
      final socket = await Socket.connect(
        '127.0.0.1',
        port,
        timeout: const Duration(milliseconds: 100),
      );

      socket.destroy();

      // DTD typically uses WebSocket
      // Format: ws://127.0.0.1:PORT/SECRET=/ws
      // Since we don't know the SECRET, try common paths first
      final commonPaths = ['/ws', '/dtd', '/'];

      for (final path in commonPaths) {
        final uri = 'ws://127.0.0.1:$port$path';
        if (await _isDtdEndpoint(uri)) {
          return uri;
        }
      }

      return null;
    } catch (e) {
      return null;
    }
  }

  /// Verify if the endpoint is a DTD endpoint
  static Future<bool> _isDtdEndpoint(String uri) async {
    try {
      final ws = await WebSocket.connect(uri)
          .timeout(const Duration(milliseconds: 200));

      // Send DTD protocol probe request
      ws.add(jsonEncode({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'getVersion',
        'params': {},
      }));

      // Wait for response
      final responseStr = await ws.first.timeout(
        const Duration(milliseconds: 500),
      );

      final response = jsonDecode(responseStr as String);

      // Check if it's a DTD response
      final isDtd = response['result']?['protocolVersion'] != null;

      await ws.close();
      return isDtd;
    } catch (e) {
      return false;
    }
  }

  /// Query VM Service URI from DTD
  static Future<String?> _queryVmServiceFromDtd(String dtdUri) async {
    try {
      final ws = await WebSocket.connect(dtdUri)
          .timeout(const Duration(milliseconds: 500));

      // Methods that DTD might provide VM Service info:
      // 1. getVM (if supported)
      // 2. streamListen("VM") then receive events
      // 3. Read specific service registration info

      // Try method 1: getVM
      ws.add(jsonEncode({
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'getVM',
        'params': {},
      }));

      final responseStr = await ws.first.timeout(
        const Duration(milliseconds: 500),
      );

      final response = jsonDecode(responseStr as String);

      // Parse VM Service URI (if available)
      String? vmUri;

      // Possible response format:
      // { "result": { "vmServiceUri": "http://..." } }
      if (response['result']?['vmServiceUri'] != null) {
        vmUri = response['result']['vmServiceUri'] as String;
      }

      await ws.close();
      return vmUri;
    } catch (e) {
      print('   Query failed: $e');
      return null;
    }
  }
}

/// Discovery Result
class DiscoveryResult {
  final bool success;
  final String? vmServiceUri;
  final String? dtdUri;
  final String? bridgeUri;
  final String? discoveryMethod;
  final String message;
  final List<String> suggestions;

  DiscoveryResult({
    required this.success,
    this.vmServiceUri,
    this.dtdUri,
    this.bridgeUri,
    this.discoveryMethod,
    required this.message,
    this.suggestions = const [],
  });

  Map<String, dynamic> toJson() => {
        'success': success,
        'vm_service_uri': vmServiceUri,
        'dtd_uri': dtdUri,
        if (bridgeUri != null) 'bridge_uri': bridgeUri,
        'discovery_method': discoveryMethod,
        'message': message,
        if (suggestions.isNotEmpty) 'suggestions': suggestions,
      };

  @override
  String toString() => jsonEncode(toJson());
}

/// Usage Example
///
/// ```dart
/// // Auto-discover VM Service
/// final result = await DtdServiceDiscovery.discover();
///
/// if (result.success) {
///   print('Found VM Service: ${result.vmServiceUri}');
///   final client = FlutterSkillClient(result.vmServiceUri!);
///   await client.connect();
/// } else {
///   print('Warning: ${result.message}');
///   print('Suggestions: ${result.suggestions.join("\n")}');
/// }
/// ```
