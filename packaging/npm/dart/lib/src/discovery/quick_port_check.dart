import 'dart:io';
import 'dart:convert';
import 'dart:async';

/// Quick port check for VM Service
///
/// Directly queries HTTP port to get WebSocket URI without DTD dependency
class QuickPortCheck {
  /// Check a single port and return WebSocket URI
  static Future<String?> checkPort(int port) async {
    try {
      // 1. Try connecting to HTTP port
      final client = HttpClient();
      client.connectionTimeout = const Duration(milliseconds: 500);

      final request = await client.get('127.0.0.1', port, '/json/version');
      final response = await request.close();

      if (response.statusCode == 200) {
        // 2. Read response
        final jsonStr = await response.transform(utf8.decoder).join();
        final json = jsonDecode(jsonStr) as Map<String, dynamic>;

        // 3. Extract WebSocket URI
        // VM Service usually returns WebSocket debugger URL in 'webSocketDebuggerUrl' field
        if (json.containsKey('webSocketDebuggerUrl')) {
          client.close();
          return json['webSocketDebuggerUrl'] as String;
        }
      }

      client.close();
    } catch (e) {
      // Port unavailable or not a VM Service
    }

    // Try alternative method: query root path directly
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(milliseconds: 500);

      final request = await client.get('127.0.0.1', port, '/');
      final response = await request.close();

      if (response.statusCode == 200) {
        // Read HTML response and look for ws:// URI
        final html = await response.transform(utf8.decoder).join();

        // Find ws:// URI
        final wsRegex = RegExp(r'ws://[^\s"<>]+');
        final match = wsRegex.firstMatch(html);

        if (match != null) {
          client.close();
          return match.group(0);
        }
      }

      client.close();
    } catch (e) {
      // Failed
    }

    return null;
  }

  /// Check multiple ports sequentially (DEPRECATED - use checkPortsParallel)
  @Deprecated('Use checkPortsParallel for better performance')
  static Future<String?> checkPorts(List<int> ports) async {
    for (final port in ports) {
      final uri = await checkPort(port);
      if (uri != null) {
        return uri;
      }
    }
    return null;
  }

  /// Check multiple ports in parallel (much faster!)
  ///
  /// Returns the first successful result or null if all fail
  static Future<String?> checkPortsParallel(List<int> ports) async {
    if (ports.isEmpty) return null;

    // Launch all port checks in parallel
    final futures = ports.map((port) => checkPort(port)).toList();

    try {
      // Wait for first successful result (or all to complete)
      return await Future.any([
        ...futures.map((f) async {
          final result = await f;
          if (result != null) return result;
          // If null, throw to continue waiting for other futures
          throw StateError('Port check returned null');
        }),
        // Fallback: wait for all to complete and return null
        Future.wait(futures).then((_) => null as String?),
      ]);
    } catch (e) {
      // All futures completed with null
      return null;
    }
  }
}
