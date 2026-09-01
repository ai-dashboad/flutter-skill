import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../engine/skill_engine.dart';

/// MCP (Model Context Protocol) adapter.
///
/// Translates between MCP JSON-RPC over stdio and the SkillEngine.
/// This is one of potentially many protocol adapters:
/// - McpAdapter (this) — MCP over stdio
/// - Future: WebMcpAdapter — Chrome WebMCP
/// - Future: RestAdapter — HTTP REST API
/// - Future: SseAdapter — MCP over SSE
/// - Future: FunctionCallAdapter — OpenAI function calling format
class McpAdapter {
  final SkillEngine engine;
  final String serverName;
  final String serverVersion;

  // Plugin tools from external sources
  List<Map<String, dynamic>> pluginTools = [];

  // Callback for custom request handling (connection management, etc.)
  // Returns null if the adapter should handle it, or a response map.
  final Future<Map<String, dynamic>?> Function(
      String method, Map<String, dynamic> params)? onCustomRequest;

  // Callback when a tool is called (for logging, recording, etc.)
  final void Function(String toolName, Map<String, dynamic> args)? onToolCall;

  // Callback to format tool results into MCP content format
  final List<Map<String, dynamic>> Function(dynamic result)? formatResult;

  McpAdapter({
    required this.engine,
    this.serverName = 'flutter-skill',
    this.serverVersion = '0.8.3',
    this.onCustomRequest,
    this.onToolCall,
    this.formatResult,
  });

  /// Start listening on stdin and writing to stdout.
  void start() {
    _listenStdio();
  }

  // --------------- MCP Protocol Messages ---------------

  /// Handle MCP initialize request.
  Map<String, dynamic> handleInitialize(Map<String, dynamic> params) {
    return {
      'protocolVersion': '2024-11-05',
      'capabilities': {
        'tools': {'listChanged': true},
      },
      'serverInfo': {
        'name': serverName,
        'version': serverVersion,
      },
    };
  }

  /// Handle MCP tools/list request.
  Map<String, dynamic> handleToolsList() {
    final tools = engine.getAvailableTools(pluginTools: pluginTools);
    return {'tools': tools};
  }

  /// Handle MCP tools/call request.
  Future<Map<String, dynamic>> handleToolCall(
      String name, Map<String, dynamic> args) async {
    onToolCall?.call(name, args);

    try {
      final result = await engine.executeTool(name, args);
      final content = _formatToolResult(result);
      return {'content': content};
    } catch (e) {
      return {
        'content': [
          {'type': 'text', 'text': 'Error: $e'}
        ],
        'isError': true,
      };
    }
  }

  // --------------- Result Formatting ---------------

  List<Map<String, dynamic>> _formatToolResult(dynamic result) {
    if (formatResult != null) return formatResult!(result);

    // Default MCP formatting
    if (result is Map) {
      // Check for image data
      final imageData = result['image'] ?? result['screenshot'];
      if (imageData is String && imageData.length > 100) {
        final content = <Map<String, dynamic>>[
          {
            'type': 'image',
            'data': imageData,
            'mimeType': result['mimeType'] ?? 'image/png',
          }
        ];
        // Add text summary if present
        final textFields = Map<String, dynamic>.from(result)
          ..remove('image')
          ..remove('screenshot')
          ..remove('mimeType');
        if (textFields.isNotEmpty) {
          content.add({'type': 'text', 'text': jsonEncode(textFields)});
        }
        return content;
      }
      return [
        {'type': 'text', 'text': jsonEncode(result)}
      ];
    }
    if (result is List) {
      return [
        {'type': 'text', 'text': jsonEncode(result)}
      ];
    }
    return [
      {'type': 'text', 'text': result?.toString() ?? 'OK'}
    ];
  }

  // --------------- stdio Transport ---------------

  void _listenStdio() {
    String buffer = '';

    stdin.listen((data) {
      buffer += utf8.decode(data);

      while (true) {
        final headerEnd = buffer.indexOf('\r\n\r\n');
        if (headerEnd < 0) break;

        final headerStr = buffer.substring(0, headerEnd);
        final match = RegExp(r'Content-Length:\s*(\d+)', caseSensitive: false)
            .firstMatch(headerStr);
        if (match == null) break;

        final contentLength = int.parse(match.group(1)!);
        final bodyStart = headerEnd + 4;
        if (buffer.length < bodyStart + contentLength) break;

        final body = buffer.substring(bodyStart, bodyStart + contentLength);
        buffer = buffer.substring(bodyStart + contentLength);

        _handleMessage(body);
      }
    });
  }

  Future<void> _handleMessage(String body) async {
    Map<String, dynamic> request;
    try {
      request = jsonDecode(body) as Map<String, dynamic>;
    } catch (e) {
      _sendResponse({
        'jsonrpc': '2.0',
        'id': null,
        'error': {'code': -32700, 'message': 'Parse error'},
      });
      return;
    }

    final id = request['id'];
    final method = request['method'] as String?;
    final params = (request['params'] as Map<String, dynamic>?) ?? {};

    try {
      Map<String, dynamic>? result;

      // Check custom handler first
      if (onCustomRequest != null) {
        result = await onCustomRequest!(method ?? '', params);
      }

      if (result == null) {
        switch (method) {
          case 'initialize':
            result = handleInitialize(params);
            break;

          case 'initialized':
            // Notification, no response needed
            return;

          case 'tools/list':
            result = handleToolsList();
            break;

          case 'tools/call':
            final name = params['name'] as String? ?? '';
            final args = (params['arguments'] as Map<String, dynamic>?) ?? {};
            result = await handleToolCall(name, args);
            break;

          case 'notifications/cancelled':
            // Notification, no response needed
            return;

          default:
            _sendResponse({
              'jsonrpc': '2.0',
              'id': id,
              'error': {'code': -32601, 'message': 'Method not found: $method'},
            });
            return;
        }
      }

      _sendResponse({
        'jsonrpc': '2.0',
        'id': id,
        'result': result,
      });
    } catch (e) {
      _sendResponse({
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': -32000, 'message': e.toString()},
      });
    }
  }

  void _sendResponse(Map<String, dynamic> response) {
    final body = jsonEncode(response);
    final header = 'Content-Length: ${utf8.encode(body).length}\r\n\r\n';
    stdout.write(header);
    stdout.write(body);
  }
}
