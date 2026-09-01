import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'server_registry.dart';

/// Client that connects to a named [SkillServer] over TCP (or Unix socket on
/// macOS/Linux) and sends JSON-RPC 2.0 requests.
class SkillClient {
  final String? serverId;
  final int? directPort;

  SkillClient.byId(String id)
      : serverId = id,
        directPort = null {
    if (!RegExp(r'^[a-zA-Z0-9_\-]+$').hasMatch(id)) {
      throw ArgumentError(
          'Invalid server id "$id". Only letters, numbers, hyphens, and underscores are allowed.');
    }
  }

  SkillClient.byPort(int port)
      : serverId = null,
        directPort = port;

  /// Send a JSON-RPC 2.0 request and return the result map.
  ///
  /// Throws if the server returns an error or the connection fails.
  Future<Map<String, dynamic>> call(
      String method, Map<String, dynamic> params) async {
    const id = 1; // Each client instance makes one call; id is always 1.

    Socket socket;
    try {
      socket = await _connect();
    } catch (e) {
      throw Exception(
          'Could not connect to server "${serverId ?? directPort}": $e');
    }

    try {
      final request = jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      });

      socket.writeln(request);

      // Read lines until we get the response for our request id.
      final completer = Completer<Map<String, dynamic>>();

      late StreamSubscription<String> subscription;
      subscription = socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
        (line) {
          if (completer.isCompleted) return;
          try {
            final response = jsonDecode(line) as Map<String, dynamic>;
            if (response['id'] == id) {
              subscription.cancel();
              if (response.containsKey('error')) {
                final err = response['error'] as Map<String, dynamic>;
                completer.completeError(
                    Exception(err['message'] ?? 'Unknown error'));
              } else {
                completer.complete(
                    response['result'] as Map<String, dynamic>? ?? {});
              }
            }
          } catch (_) {
            // Ignore lines that are not valid JSON for our id.
          }
        },
        onError: (Object e) {
          if (!completer.isCompleted) completer.completeError(e);
        },
        onDone: () {
          if (!completer.isCompleted) {
            completer.completeError(
                Exception('Connection closed before response received'));
          }
        },
        cancelOnError: true,
      );

      return await completer.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () =>
            throw TimeoutException('Request timed out', const Duration(seconds: 30)),
      );
    } finally {
      await socket.close().catchError((_) {});
    }
  }

  Future<Socket> _connect() async {
    // Prefer Unix socket on non-Windows when available.
    if (!Platform.isWindows && serverId != null) {
      final sockPath = ServerRegistry.unixSocketPath(serverId!);
      if (sockPath != null && await File(sockPath).exists()) {
        try {
          return await Socket.connect(
            InternetAddress(sockPath, type: InternetAddressType.unix),
            0,
            timeout: const Duration(milliseconds: 500),
          );
        } catch (_) {
          // Fall through to TCP.
        }
      }
    }

    final port = await _resolvePort();
    return Socket.connect('127.0.0.1', port,
        timeout: const Duration(seconds: 5));
  }

  Future<int> _resolvePort() async {
    if (directPort != null) return directPort!;
    final entry = await ServerRegistry.get(serverId!);
    if (entry == null) {
      throw Exception('No server registered with id "$serverId". '
          'Run: flutter_skill connect --id=$serverId --port=<port>');
    }
    return entry.port;
  }
}
