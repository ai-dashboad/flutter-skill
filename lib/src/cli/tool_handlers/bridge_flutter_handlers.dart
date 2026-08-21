part of '../server.dart';

extension _BridgeFlutterHandlers on FlutterMcpServer {
  /// Handle bridge/Flutter platform tools (non-CDP, non-connection)
  Future<dynamic> _handleBridgeFlutterTool(
      String name, Map<String, dynamic> args, AppDriver? client) async {
    final handlers = [
      _handleInspectionTool,
      _handleInteractionTool,
      _handleScreenshotTool,
      _handleNavigationTool,
      _handleLoggingTool,
      _handleBatchCoordTool,
      _handleAssertionTool,
      _handleStateTool,
    ];
    for (final handler in handlers) {
      final result = await handler(name, args, client);
      if (result != null) return result;
    }

    // AppMCP: discover/call tools on bridge platforms
    if (name == 'discover_page_tools' && _client is BridgeDriver) {
      return await (_client as BridgeDriver).discoverTools();
    }
    if (name == 'call_page_tool' && _client is BridgeDriver) {
      final toolName = args['name'] as String? ?? '';
      final toolParams = (args['params'] as Map<String, dynamic>?) ?? {};
      return await (_client as BridgeDriver).callTool(toolName, toolParams);
    }

    throw Exception("Tool '$name' is not implemented for the "
        "${client.runtimeType} driver (or returned no result)");
  }
}
