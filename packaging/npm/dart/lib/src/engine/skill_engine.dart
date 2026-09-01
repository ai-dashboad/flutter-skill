import 'dart:async';

import '../bridge/cdp_driver.dart';
import '../drivers/app_driver.dart';
import '../drivers/bridge_driver.dart';
import '../drivers/flutter_driver.dart';
import 'tool_registry.dart';

/// Protocol-agnostic skill engine.
///
/// Contains all capabilities (160+ tools) independent of any transport.
/// Can be used by MCP, WebMCP, REST, Function Calling, or any future protocol.
///
/// This is a facade that currently delegates to the tool execution logic
/// in FlutterMcpServer. As we progressively refactor, more logic will
/// move directly into this class.
abstract class SkillEngine {
  // --------------- Connection State ---------------

  /// The currently active app driver (bridge, flutter, or CDP).
  AppDriver? get client;

  /// The CDP driver, if connected via Chrome DevTools Protocol.
  CdpDriver? get cdpDriver;

  /// Whether any connection is active.
  bool get isConnected;

  /// Connection type: 'cdp', 'bridge', 'flutter', or null.
  String? get connectionType;

  // --------------- Tool Registry ---------------

  /// Get all tool definitions available for the current connection.
  List<Map<String, dynamic>> getAvailableTools({
    List<Map<String, dynamic>> pluginTools = const [],
  });

  /// Get a specific tool definition by name.
  Map<String, dynamic>? getToolDefinition(String name);

  // --------------- Tool Execution ---------------

  /// Execute a tool by name with arguments.
  /// Returns the tool result (format depends on the tool).
  /// Throws on error.
  Future<dynamic> executeTool(String name, Map<String, dynamic> args);

  // --------------- Connection Management ---------------

  /// Connect via Chrome DevTools Protocol.
  Future<void> connectCdp({
    int port = 9222,
    String? url,
    bool launchChrome = true,
    String? chromePath,
    bool headless = false,
    String? proxy,
    bool ignoreSsl = false,
    int maxTabs = 20,
  });

  /// Connect to an app via bridge protocol (WebSocket).
  Future<void> connectBridge({String? host, int? port});

  /// Connect to a Flutter app via VM Service.
  Future<void> connectFlutter({String? vmServiceUri});

  /// Auto-discover and connect to any running app.
  Future<void> scanAndConnect();

  /// Disconnect from the current app.
  Future<void> disconnect();

  // --------------- Lifecycle ---------------

  /// Shut down the engine and release resources.
  Future<void> dispose();
}

/// Default implementation that wraps FlutterMcpServer's existing logic.
///
/// Phase 1: Delegates to server internals via callbacks.
/// Phase 2+: Logic progressively moves here.
class DefaultSkillEngine implements SkillEngine {
  // Callbacks to FlutterMcpServer methods (temporary bridge during refactor)
  final Future<dynamic> Function(String name, Map<String, dynamic> args)?
      _executeToolFn;
  final Future<void> Function()? _disconnectFn;
  final Future<void> Function()? _disposeFn;

  // State references from FlutterMcpServer
  AppDriver? _client;
  CdpDriver? _cdpDriver;
  DefaultSkillEngine({
    Future<dynamic> Function(String, Map<String, dynamic>)? executeToolFn,
    Future<void> Function()? disconnectFn,
    Future<void> Function()? disposeFn,
  })  : _executeToolFn = executeToolFn,
        _disconnectFn = disconnectFn,
        _disposeFn = disposeFn;

  // Update state from server (called by FlutterMcpServer)
  void updateClient(AppDriver? client) => _client = client;
  void updateCdpDriver(CdpDriver? cdp) => _cdpDriver = cdp;

  @override
  AppDriver? get client => _client;

  @override
  CdpDriver? get cdpDriver => _cdpDriver;

  @override
  bool get isConnected => _client != null || _cdpDriver != null;

  @override
  String? get connectionType {
    if (_cdpDriver != null) return 'cdp';
    if (_client is BridgeDriver) return 'bridge';
    if (_client is FlutterSkillClient) return 'flutter';
    return null;
  }

  @override
  List<Map<String, dynamic>> getAvailableTools({
    List<Map<String, dynamic>> pluginTools = const [],
  }) {
    return ToolRegistry.getFilteredTools(
      hasCdp: _cdpDriver != null,
      hasBridge: _client is BridgeDriver && _cdpDriver == null,
      hasFlutter: _client is FlutterSkillClient && _client is! BridgeDriver,
      hasConnection: isConnected,
      pluginTools: pluginTools,
    );
  }

  @override
  Map<String, dynamic>? getToolDefinition(String name) {
    final tools = ToolRegistry.getAllToolDefinitions();
    try {
      return tools.firstWhere((t) => t['name'] == name);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<dynamic> executeTool(String name, Map<String, dynamic> args) async {
    if (_executeToolFn == null) {
      throw StateError('SkillEngine not wired to execution backend');
    }
    return _executeToolFn!(name, args);
  }

  // Connection methods — Phase 1: not yet extracted from server
  @override
  Future<void> connectCdp({
    int port = 9222,
    String? url,
    bool launchChrome = true,
    String? chromePath,
    bool headless = false,
    String? proxy,
    bool ignoreSsl = false,
    int maxTabs = 20,
  }) async {
    // Delegate to executeTool('connect_cdp', ...)
    await executeTool('connect_cdp', {
      'port': port,
      if (url != null) 'url': url,
      'launch_chrome': launchChrome,
      if (chromePath != null) 'chrome_path': chromePath,
      'headless': headless,
      if (proxy != null) 'proxy': proxy,
      'ignore_ssl': ignoreSsl,
      'max_tabs': maxTabs,
    });
  }

  @override
  Future<void> connectBridge({String? host, int? port}) async {
    await executeTool('scan_and_connect', {
      if (host != null) 'host': host,
      if (port != null) 'port': port,
    });
  }

  @override
  Future<void> connectFlutter({String? vmServiceUri}) async {
    await executeTool('connect_app', {
      if (vmServiceUri != null) 'uri': vmServiceUri,
    });
  }

  @override
  Future<void> scanAndConnect() async {
    await executeTool('scan_and_connect', {});
  }

  @override
  Future<void> disconnect() async {
    if (_disconnectFn != null) {
      await _disconnectFn!();
    } else {
      await executeTool('disconnect', {});
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposeFn != null) await _disposeFn!();
  }
}
