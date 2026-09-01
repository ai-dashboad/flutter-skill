import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'package:http/http.dart' as http;
import '../bridge/bridge_protocol.dart';
import '../bridge/cdp_driver.dart';
import '../bridge/web_bridge_listener.dart';
import '../discovery/bridge_discovery.dart';
import '../discovery/process_based_discovery.dart';
import '../drivers/web_bridge_driver.dart';
import '../drivers/app_driver.dart';
import '../drivers/bridge_driver.dart';
import '../drivers/flutter_driver.dart';
import '../drivers/native_driver.dart';
import '../diagnostics/error_reporter.dart';
import '../engine/skill_engine.dart';
import '../engine/tool_registry.dart';
import 'setup.dart';
import 'security.dart';

part 'tool_handlers/cdp_tool_handlers.dart';
part 'tool_handlers/tool_definitions.dart';
part 'tool_handlers/report_handlers.dart';
part 'tool_handlers/diagnosis_handlers.dart';
part 'tool_handlers/flutter_helpers.dart';
part 'tool_handlers/plugin_handlers.dart';
part 'tool_handlers/discovery_helpers.dart';
part 'tool_handlers/bridge_flutter_handlers.dart';
part 'tool_handlers/bf_inspection.dart';
part 'tool_handlers/bf_interaction.dart';
part 'tool_handlers/bf_screenshot.dart';
part 'tool_handlers/bf_navigation.dart';
part 'tool_handlers/bf_logging.dart';
part 'tool_handlers/bf_batch.dart';
part 'tool_handlers/bf_assertions.dart';
part 'tool_handlers/bf_state.dart';
part 'tool_handlers/connection_handlers.dart';
part 'tool_handlers/cdp_connection_handlers.dart';
part 'tool_handlers/dev_tool_handlers.dart';
part 'tool_handlers/native_handlers.dart';
part 'tool_handlers/auth_handlers.dart';
part 'tool_handlers/recording_handlers.dart';
part 'tool_handlers/i18n_handlers.dart';
part 'tool_handlers/performance_handlers.dart';
part 'tool_handlers/parallel_handlers.dart';
part 'tool_handlers/api_handlers.dart';
part 'tool_handlers/reliability_handlers.dart';
part 'tool_handlers/visual_regression_handlers.dart';
part 'tool_handlers/multi_device_handlers.dart';
part 'tool_handlers/accessibility_deep_handlers.dart';
part 'tool_handlers/session_handlers.dart';
part 'tool_handlers/self_healing_handlers.dart';
part 'tool_handlers/network_mock_handlers.dart';
part 'tool_handlers/network_condition_handlers.dart';
part 'tool_handlers/log_analysis_handlers.dart';
part 'tool_handlers/cross_browser_handlers.dart';
part 'tool_handlers/coverage_handlers.dart';
part 'tool_handlers/smart_wait_handlers.dart';
part 'tool_handlers/data_driven_handlers.dart';
part 'tool_handlers/security_handlers.dart';
part 'tool_handlers/diff_handlers.dart';
part 'tool_handlers/bug_report_handlers.dart';
part 'tool_handlers/fixture_handlers.dart';
part 'tool_handlers/explore_handlers.dart';

const String currentVersion = '0.9.36';

/// Session information for multi-session support
class SessionInfo {
  final String id;
  final String name;
  final String projectPath;
  final String deviceId;
  final int port;
  final String vmServiceUri;
  final DateTime createdAt;

  SessionInfo({
    required this.id,
    required this.name,
    required this.projectPath,
    required this.deviceId,
    required this.port,
    required this.vmServiceUri,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'project_path': projectPath,
        'device_id': deviceId,
        'port': port,
        'vm_service_uri': vmServiceUri,
        'created_at': createdAt.toIso8601String(),
      };
}

Future<void> runServer(List<String> args) async {
  // Check for updates in background
  _checkForUpdates();

  // Acquire lock to prevent multiple instances
  final lockFile = await _acquireLock();
  if (lockFile == null) {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '~';
    _printCliError(
      'Another flutter-skill server is already running',
      'A lock file prevents starting a second instance.',
      fixes: [
        'Stop the existing server first',
        'Or delete the stale lock: rm "$home/.flutter_skill.lock"',
        'On Windows: del "%USERPROFILE%\\.flutter_skill.lock"',
      ],
    );
    exit(1);
  }

  try {
    final server = FlutterMcpServer();

    String? autoUrl;
    int? cdpPort;

    // Parse flags
    for (final arg in args) {
      if (arg.startsWith('--bridge-port=')) {
        final port = int.tryParse(arg.substring('--bridge-port='.length)) ??
            bridgeDefaultPort;
        await server.startBridgeListener(port);
      } else if (arg == '--bridge-port') {
        await server.startBridgeListener(bridgeDefaultPort);
      } else if (arg.startsWith('--url=')) {
        autoUrl = arg.substring('--url='.length);
      } else if (arg.startsWith('--cdp-port=')) {
        cdpPort = int.tryParse(arg.substring('--cdp-port='.length));
      } else if (arg.startsWith('--plugins-dir=')) {
        server._pluginsDir = arg.substring('--plugins-dir='.length);
      }
    }

    await server._loadPlugins();

    if (autoUrl != null) {
      server._autoConnectUrl = autoUrl;
      server._autoConnectCdpPort = cdpPort;
    }

    await server.run();
  } finally {
    // Release lock on exit
    await _releaseLock(lockFile);
  }
}

/// Check pub.dev for newer version
Future<void> _checkForUpdates() async {
  try {
    final response = await http
        .get(
          Uri.parse('https://pub.dev/api/packages/flutter_skill'),
        )
        .timeout(const Duration(seconds: 5));

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      final latestVersion = data['latest']?['version'] as String?;

      if (latestVersion != null &&
          _isNewerVersion(latestVersion, currentVersion)) {
        stderr.writeln('');
        stderr.writeln(
            '╔══════════════════════════════════════════════════════════╗');
        stderr.writeln(
            '║  flutter-skill v$latestVersion available (current: v$currentVersion)');
        stderr.writeln(
            '║                                                          ║');
        stderr.writeln(
            '║  Update with:                                            ║');
        stderr.writeln(
            '║    dart pub global activate flutter_skill                ║');
        stderr.writeln(
            '║  Or:                                                     ║');
        stderr.writeln(
            '║    npm update -g flutter-skill                       ║');
        stderr.writeln(
            '╚══════════════════════════════════════════════════════════╝');
        stderr.writeln('');
      }
    }
  } catch (e) {
    // Ignore update check errors
  }
}

/// Compare semantic versions
bool _isNewerVersion(String latest, String current) {
  final latestParts = latest.split('.').map(int.tryParse).toList();
  final currentParts = current.split('.').map(int.tryParse).toList();

  for (int i = 0; i < 3; i++) {
    final l = i < latestParts.length ? (latestParts[i] ?? 0) : 0;
    final c = i < currentParts.length ? (currentParts[i] ?? 0) : 0;
    if (l > c) return true;
    if (l < c) return false;
  }
  return false;
}

class FlutterMcpServer {
  /// The protocol-agnostic skill engine.
  /// Use this to execute tools from any protocol adapter.
  late final SkillEngine skillEngine;

  FlutterMcpServer() {
    skillEngine = _ServerSkillEngine(this);
  }

  // Multi-session support
  final Map<String, AppDriver> _clients = {};
  final Map<String, SessionInfo> _sessions = {};
  String? _activeSessionId;

  // Auto-connect CDP on startup (set via --url flag)
  String? _autoConnectUrl;
  int? _autoConnectCdpPort;

  // Plugin system
  String _pluginsDir =
      '${Platform.environment['HOME'] ?? '.'}/.flutter-skill/plugins';
  final List<Map<String, dynamic>> _pluginTools = [];

  // Cancellable operations
  final Map<String, Completer<void>> _activeCancellables = {};

  // Last known connection info for auto-reconnect
  String? _lastConnectionUri;
  int? _lastConnectionPort;

  // Legacy single client support (for backward compatibility)
  AppDriver? get _client => _activeSessionId != null
      ? _clients[_activeSessionId]
      : _clients.values.isNotEmpty
          ? _clients.values.first
          : null;

  Process? _flutterProcess;

  // Recording state
  bool _isRecording = false;
  final List<Map<String, dynamic>> _recordedSteps = [];
  DateTime? _recordingStartTime;

  // Performance monitoring state
  bool _perfCollecting = false;
  DateTime? _perfStartTime;
  final List<Map<String, dynamic>> _perfMetricSnapshots = [];

  // Video recording state
  Process? _videoProcess;
  String? _videoPath;
  String? _videoPlatform;
  String? _videoDevicePath;

  // CDP driver for vanilla web testing
  CdpDriver? _cdpDriver;

  // Network mock state
  _NetworkMockState? _networkMockState;

  // Web bridge listener for browser-based SDKs
  WebBridgeListener? _webBridgeListener;

  // Coverage tracking state
  bool _coverageTracking = false;
  final Set<String> _coveragePages = {};
  final Set<String> _coverageElements = {};
  final List<Map<String, dynamic>> _coverageActions = [];

  // Native platform drivers (for interacting with native OS views)
  final Map<String, NativeDriver> _nativeDrivers = {};

  /// Get or create native driver for the active session
  Future<NativeDriver?> _getNativeDriver(Map<String, dynamic> args) async {
    final sessionId = args['session_id'] as String? ?? _activeSessionId;
    final key = sessionId ?? '_default';

    if (_nativeDrivers.containsKey(key)) return _nativeDrivers[key];

    String? deviceId;
    if (sessionId != null && _sessions.containsKey(sessionId)) {
      deviceId = _sessions[sessionId]!.deviceId;
    }

    final driver = await NativeDriver.create(deviceId);
    if (driver != null) {
      _nativeDrivers[key] = driver;
    }
    return driver;
  }

  /// Start the web bridge listener for browser-based SDKs.
  Future<void> startBridgeListener(int port) async {
    if (_webBridgeListener != null) return;
    final listener = WebBridgeListener();
    String? _webSessionId;
    listener.onClientConnected = (_) {
      // Delay to let WS connection stabilize (SDK sends bridge.hello, may reconnect)
      Future.delayed(const Duration(milliseconds: 2000), () async {
        if (!listener.hasClient) return; // Already disconnected
        try {
          final driver = WebBridgeDriver(listener);
          await driver.connect();
          final sessionId = _webSessionId ?? _generateSessionId();
          _webSessionId = sessionId;
          _clients[sessionId] = driver;
          _sessions[sessionId] = SessionInfo(
            id: sessionId,
            name: 'Web app (bridge listener)',
            projectPath: 'web',
            deviceId: 'web',
            port: port,
            vmServiceUri: 'ws://127.0.0.1:$port',
          );
          _activeSessionId = sessionId;
          stderr
              .writeln('Browser client connected — session $sessionId created');
        } catch (e) {
          stderr.writeln('Failed to initialize web bridge session: $e');
        }
      });
    };
    listener.onClientDisconnected = () {
      stderr.writeln('Browser client disconnected from bridge listener');
    };
    try {
      await listener.start(port);
    } on SocketException catch (e) {
      if (e.message.contains('Address already in use') ||
          e.osError?.errorCode == 98 ||
          e.osError?.errorCode == 48) {
        _printCliError(
          'Port $port is already in use',
          'Another process is already using this port.',
          fixes: [
            'Run: lsof -i :$port',
            'Kill the process using that port',
            'Or start with a different port: flutter-skill --bridge-port=9090',
          ],
        );
        exit(1);
      }
      rethrow;
    }
    _webBridgeListener = listener;
    stderr.writeln('Bridge listener started on ws://127.0.0.1:$port');
  }

  Future<void> run() async {
    final done = Completer<void>();

    // `allowMalformed: true` replaces invalid byte sequences with U+FFFD
    // instead of throwing. A strict decoder raises FormatException on the
    // *stream*, which bypasses the per-line try/catch below and kills the
    // process — a single garbled byte from any client is enough to end the
    // session. Malformed bytes now degrade into an ordinary parse error.
    stdin
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(
      (line) async {
        // A failure while handling one frame must never end the session, so
        // every path here is guarded and answers with a JSON-RPC error.
        try {
          if (line.trim().isEmpty) return;
          final dynamic request;
          try {
            request = jsonDecode(line);
          } catch (e) {
            _sendProtocolError(-32700, 'Parse error: $e');
            return;
          }
          if (request is Map<String, dynamic>) {
            await _handleRequest(request);
          } else {
            // Valid JSON, but not a JSON-RPC request object.
            _sendProtocolError(
                -32600, 'Invalid Request: expected a JSON object');
          }
        } catch (e) {
          _sendProtocolError(-32603, 'Internal error: $e');
        }
      },
      // Without an onError handler a stream-level error is unhandled and
      // terminates the isolate. Keep reading instead.
      onError: (Object e) {
        _sendProtocolError(-32700, 'Parse error: $e');
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      cancelOnError: false,
    );

    // Keep `runServer` awaiting until stdin closes; otherwise it returns
    // immediately and releases the single-instance lock while the server is
    // still serving requests.
    await done.future;
  }

  Future<void> _handleRequest(Map<String, dynamic> request) async {
    final id = request['id'];
    final method = request['method'];
    final params = request['params'] as Map<String, dynamic>? ?? {};

    try {
      if (method == 'initialize') {
        _sendResult(id, {
          "capabilities": {
            "tools": {"listChanged": true},
            "resources": {}
          },
          "protocolVersion": "2024-11-05",
          "serverInfo": {"name": "flutter-skill", "version": currentVersion},
        });
        // Auto-connect CDP if --url was provided
        if (_autoConnectUrl != null) {
          final url = _autoConnectUrl!;
          _autoConnectUrl = null; // Only once
          Future(() async {
            try {
              final port = _autoConnectCdpPort ?? 9222;
              stderr.writeln('Auto-connecting CDP to $url (port $port)...');
              final result = await _executeTool('connect_cdp', {
                'url': url,
                'port': port,
                'launch_chrome': true,
              });
              stderr.writeln('CDP auto-connect: $result');
              _sendNotification('notifications/tools/list_changed');
            } catch (e) {
              stderr.writeln('CDP auto-connect failed: $e');
            }
          });
        }
      } else if (method == 'notifications/initialized') {
        // No op
      } else if (method == 'tools/list') {
        _sendResult(id, {"tools": skillEngine.getAvailableTools()});
      } else if (method == 'tools/call') {
        final name = params['name'];
        final args = params['arguments'] as Map<String, dynamic>? ?? {};
        final result = await _executeTool(name, args);
        // Recording middleware
        if (_isRecording &&
            [
              'tap',
              'enter_text',
              'scroll',
              'swipe',
              'go_back',
              'press_key',
              'screenshot'
            ].contains(name)) {
          _recordedSteps.add({
            'step': _recordedSteps.length + 1,
            'tool': name,
            'params': args,
            'timestamp_ms': DateTime.now().millisecondsSinceEpoch,
            'result': result is Map ? (result['success'] ?? true) : true,
          });
        }
        _sendResult(id, {
          "content": [
            {"type": "text", "text": jsonEncode(result)},
          ],
        });
        // Notify MCP clients to refresh tool list after connection state changes.
        // This allows clients to discover the full automation toolkit after connecting.
        const _connectionStateTools = {
          'connect_app',
          'launch_app',
          'scan_and_connect',
          'connect_cdp',
          'connect_openclaw_browser',
          'connect_webmcp',
          'disconnect',
        };
        if (_connectionStateTools.contains(name)) {
          final succeeded = result is Map
              ? (result['success'] == true ||
                  result['connected'] == true ||
                  name == 'disconnect')
              : false;
          if (succeeded) {
            _sendNotification('notifications/tools/list_changed');
          }
        }
      }
    } catch (e, stackTrace) {
      if (id != null) {
        _sendError(id, -32603, "Internal error: $e");
      }

      // Auto-report critical errors
      if (_shouldReportError(e)) {
        // Auto-report is enabled by default (can be disabled with env var)
        final autoReport =
            Platform.environment['FLUTTER_SKILL_AUTO_REPORT'] != 'false';

        await errorReporter.reportError(
          errorType: e.runtimeType.toString(),
          errorMessage: e.toString(),
          stackTrace: stackTrace,
          context: {
            'method': method,
            'params': params,
            'client_connected': _client?.isConnected ?? false,
          },
          autoCreate: autoReport,
        );
      }
    }
  }

  /// Get the client for a specific session or the active session
  AppDriver? _getClient(Map<String, dynamic> args) {
    final sessionId = args['session_id'] as String?;

    if (sessionId != null) {
      return _clients[sessionId];
    }

    // Use active session or first available
    return _client;
  }

  /// Generate a unique session ID
  String _generateSessionId() {
    return 'session_${DateTime.now().millisecondsSinceEpoch}';
  }

  /// Load plugin tools from the plugins directory

  /// Check if an error is retryable (transient connection/timeout issues)
  bool _isRetryableError(dynamic error) {
    final msg = error.toString().toLowerCase();
    // NOT retryable
    if (msg.contains('unknown tool')) return false;
    if (msg.contains('required') && msg.contains('parameter')) return false;
    if (msg.contains('element not found')) return false;
    if (msg.contains('is required')) return false;
    // Retryable
    if (msg.contains('websocket')) return true;
    if (msg.contains('connection closed')) return true;
    if (msg.contains('connection reset')) return true;
    if (msg.contains('not connected')) return true;
    if (msg.contains('connection lost')) return true;
    if (msg.contains('timed out') || msg.contains('timeout')) return true;
    if (msg.contains('socket') &&
        (msg.contains('closed') || msg.contains('error'))) return true;
    return false;
  }

  /// Attempt auto-reconnect using last known connection info
  Future<bool> _attemptAutoReconnect() async {
    if (_lastConnectionUri != null) {
      stderr.writeln(
          'Attempting auto-reconnect to $_lastConnectionUri (port: $_lastConnectionPort)...');
      try {
        final client = _clients[_activeSessionId];
        if (client is BridgeDriver) {
          await client.connect();
          stderr.writeln('Auto-reconnect successful');
          return true;
        }
      } catch (e) {
        stderr.writeln('Auto-reconnect failed: $e');
      }
    }
    if (_cdpDriver != null && !_cdpDriver!.isConnected) {
      stderr.writeln('CDP connection lost, attempting reconnect...');
      try {
        await _cdpDriver!.connect();
        stderr.writeln('CDP auto-reconnect successful');
        return true;
      } catch (e) {
        stderr.writeln('CDP auto-reconnect failed: $e');
      }
    }
    return false;
  }

  Future<dynamic> _executeTool(String name, Map<String, dynamic> args) async {
    const maxRetries = 2;
    for (int attempt = 0; attempt <= maxRetries; attempt++) {
      try {
        final result = await _executeToolInner(name, args);
        return result;
      } catch (e) {
        if (attempt < maxRetries && _isRetryableError(e)) {
          stderr.writeln('Retryable error on attempt ${attempt + 1}: $e');
          // Try auto-reconnect on connection errors
          final msg = e.toString().toLowerCase();
          if (msg.contains('not connected') ||
              msg.contains('connection lost') ||
              msg.contains('connection closed')) {
            await _attemptAutoReconnect();
          }
          await Future.delayed(Duration(milliseconds: 500 * (attempt + 1)));
          continue;
        }
        rethrow;
      }
    }
    // Unreachable, but satisfies analyzer
    throw StateError('Retry loop exited unexpectedly');
  }

  Future<dynamic> _executeToolInner(
      String name, Map<String, dynamic> args) async {
    // Download file tool (platform-independent)
    if (name == 'download_file') {
      final url = args['url'] as String?;
      final savePath = args['save_path'] as String?;
      if (url == null || savePath == null) {
        return {'success': false, 'error': 'url and save_path are required'};
      }
      try {
        final client = http.Client();
        try {
          final response = await client.get(Uri.parse(url));
          if (response.statusCode >= 200 && response.statusCode < 300) {
            final file = File(savePath);
            await file.parent.create(recursive: true);
            await file.writeAsBytes(response.bodyBytes);
            return {
              'success': true,
              'path': savePath,
              'size_bytes': response.bodyBytes.length,
              'status_code': response.statusCode
            };
          } else {
            return {
              'success': false,
              'error': 'HTTP ${response.statusCode}',
              'status_code': response.statusCode
            };
          }
        } finally {
          client.close();
        }
      } catch (e) {
        return {'success': false, 'error': e.toString()};
      }
    }

    // Cancel operation tool
    if (name == 'cancel_operation') {
      final opId = args['operation_id'] as String?;
      if (opId == null)
        return {'success': false, 'error': 'operation_id is required'};
      final completer = _activeCancellables.remove(opId);
      if (completer != null && !completer.isCompleted) {
        completer.complete();
        return {'success': true, 'cancelled': opId};
      }
      return {
        'success': false,
        'error': 'Operation not found or already completed',
        'active_operations': _activeCancellables.keys.toList()
      };
    }

    // Visual regression tools (work with or without connection for some ops)
    final vrResult = await _handleVisualRegressionTool(name, args);
    if (vrResult != null) return vrResult;

    // Delegate to handler groups
    final handlers = [
      _handleConnectionTools,
      _handleCdpConnectionTools,
      _handleDevTools,
      _handleNativeTools,
      _handleAuthTools,
      _handleRecordingTools,
      _handleI18nTools,
      _handlePerformanceTools,
      _handleParallelTools,
      _handleApiTools,
      _handleReliabilityTools,
      _handleCoverageTools,
      _handleSmartWaitTools,
      _handleDataDrivenTools,
      _handleSelfHealingTools,
      _handleNetworkMockTools,
      _handleMultiDeviceTools,
      _handleAccessibilityDeepTools,
      _handleSessionPersistenceTools,
      _handleDiffTools,
      _handleBugReportTools,
      _handleFixtureTools,
      _handleSecurityTools,
      _handleExploreTools,
      _handleNetworkConditionTools,
      _handleLogAnalysisTools,
      _handleCrossBrowserTools,
    ];
    for (final handler in handlers) {
      final result = await handler(name, args);
      if (result != null) return result;
    }

    if (name == 'list_plugins') {
      return _pluginTools.isEmpty
          ? {"plugins": [], "message": "No plugins loaded"}
          : {
              "plugins": _pluginTools
                  .map((p) =>
                      {"name": p['name'], "description": p['description']})
                  .toList()
            };
    }

    if (name == 'generate_report') {
      return _generateReport(args);
    }

    // Require connection for all other tools
    final client = _getClient(args);
    _requireConnection(client);

    if (name == 'assert_batch') {
      return _executeBatchAssertions(args, client!);
    }

    if (name == 'visual_verify') {
      return _executeVisualVerify(args, client!);
    }

    if (name == 'visual_diff') {
      return _executeVisualDiff(args, client!);
    }

    // Route to CDP driver if active connection is CDP
    if (client is CdpDriver) {
      return await _executeCdpTool(name, args, client);
    }

    return await _handleBridgeFlutterTool(name, args, client);
  }

  /// Execute a batch of actions in sequence
  Future<Map<String, dynamic>> _executeBatch(
      Map<String, dynamic> args, FlutterSkillClient client) async {
    final actions =
        (args['actions'] ?? args['commands'] ?? []) as List<dynamic>;
    final stopOnFailure = args['stop_on_failure'] ?? true;
    // A step often triggers a route/tab transition; give the next step's
    // target time to be built (default 250 ms, tunable per batch).
    final stepDelayMs = (args['step_delay_ms'] as num?)?.toInt() ?? 250;

    final results = <Map<String, dynamic>>[];
    var allSuccess = true;

    for (var i = 0; i < actions.length; i++) {
      if (i > 0 && stepDelayMs > 0) {
        await Future.delayed(Duration(milliseconds: stepDelayMs));
      }
      final action = actions[i] as Map<String, dynamic>;
      final actionName =
          (action['action'] ?? action['tool'] ?? action['name']) as String;
      // Merge nested args into action for backward compatibility
      final actionArgs = action['args'] as Map<String, dynamic>?;
      if (actionArgs != null) {
        for (final e in actionArgs.entries) {
          action.putIfAbsent(e.key, () => e.value);
        }
      }
      final startTime = DateTime.now();

      try {
        dynamic result;

        switch (actionName) {
          case 'tap':
            final tapResult =
                await client.tap(key: action['key'], text: action['text']);
            if (tapResult['success'] != true) {
              throw Exception(tapResult['message'] ?? "Element not found");
            }
            result = "Tapped";
            break;

          case 'enter_text':
            final enterResult = await client.enterText(
                action['key'], action['text'] ?? action['value']);
            if (enterResult['success'] != true) {
              throw Exception(enterResult['message'] ?? "TextField not found");
            }
            result = "Entered text";
            break;

          case 'swipe':
            final distance = (action['distance'] ?? 300).toDouble();
            await client.swipe(
              direction: action['direction'] ?? 'down',
              distance: distance,
              key: action['key'],
            );
            result = "Swiped";
            break;

          case 'wait':
            final duration = action['duration'] ?? 500;
            await Future.delayed(Duration(milliseconds: duration));
            result = "Waited ${duration}ms";
            break;

          case 'screenshot':
            final image = await client.takeScreenshot();
            result = {"image": image};
            break;

          case 'assert_visible':
            final timeout = action['timeout'] ?? 5000;
            final found = await client.waitForElement(
              key: action['key'],
              text: action['text'],
              timeout: timeout,
            );
            if (!found) throw Exception("Element not visible");
            result = "Visible";
            break;

          case 'assert_text':
            final actual = await client.getTextValue(action['key']);
            final expected = action['expected'];
            if (actual != expected) {
              throw Exception(
                  "Text mismatch: expected '$expected', got '$actual'");
            }
            result = "Text matches";
            break;

          case 'long_press':
            final duration = action['duration'] ?? 500;
            await client.longPress(
                key: action['key'], text: action['text'], duration: duration);
            result = "Long pressed";
            break;

          case 'double_tap':
            await client.doubleTap(key: action['key'], text: action['text']);
            result = "Double tapped";
            break;

          case 'scroll_to':
            await client.scrollTo(key: action['key'], text: action['text']);
            result = "Scrolled";
            break;

          default:
            throw Exception("Unknown batch action: $actionName");
        }

        final duration = DateTime.now().difference(startTime).inMilliseconds;
        results.add({
          "step": i + 1,
          "action": actionName,
          "success": true,
          "duration_ms": duration,
          "result": result,
        });
      } catch (e) {
        allSuccess = false;
        final duration = DateTime.now().difference(startTime).inMilliseconds;
        results.add({
          "step": i + 1,
          "action": actionName,
          "success": false,
          "duration_ms": duration,
          "error": e.toString(),
        });

        if (stopOnFailure) break;
      }
    }

    return {
      "success": allSuccess,
      "total_steps": actions.length,
      "completed_steps": results.length,
      "results": results,
    };
  }

  /// Gesture presets for common interactions
  /// Normalize VM Service URI to ensure correct format
  String _normalizeVmServiceUri(String uri) {
    // Remove trailing slash
    uri = uri.trimRight();
    if (uri.endsWith('/')) {
      uri = uri.substring(0, uri.length - 1);
    }

    // Handle http:// -> ws://
    if (uri.startsWith('http://')) {
      uri = uri.replaceFirst('http://', 'ws://');
    }

    // Ensure /ws suffix for VM Service
    if (!uri.endsWith('/ws') && !uri.contains('/ws?')) {
      // Check if it's a base URL like ws://127.0.0.1:50000/xxx= or ws://127.0.0.1:50000/xxx#
      // Flutter 3.41+ uses # instead of =
      if ((uri.contains('=') || uri.contains('#')) && !uri.endsWith('/ws')) {
        uri = '$uri/ws';
      }
    }

    return uri;
  }

  /// Check whether a URI looks like a DTD (Dart Tooling Daemon) URI.
  /// DTD URIs end with `/ws` but respond to DTD protocol, not VM Service.
  /// We detect this heuristically: if connecting returns -32601 "Unknown method"
  /// on getVM, it is a DTD endpoint.
  bool _looksLikeDtdUri(String error) {
    final e = error.toLowerCase();
    return e.contains('-32601') ||
        e.contains('unknown method') ||
        e.contains('method not found');
  }

  static const Map<String, Map<String, dynamic>> _gesturePresets = {
    'drawer_open': {
      'from_x': 0.0,
      'from_y': 0.5,
      'to_x': 0.75,
      'to_y': 0.5,
      'duration': 300,
    },
    'drawer_close': {
      'from_x': 0.75,
      'from_y': 0.5,
      'to_x': 0.0,
      'to_y': 0.5,
      'duration': 300,
    },
    'pull_refresh': {
      'from_x': 0.5,
      'from_y': 0.15,
      'to_x': 0.5,
      'to_y': 0.6,
      'duration': 500,
    },
    'page_back': {
      'from_x': 0.02,
      'from_y': 0.5,
      'to_x': 0.8,
      'to_y': 0.5,
      'duration': 250,
    },
    'swipe_left': {
      'from_x': 0.8,
      'from_y': 0.5,
      'to_x': 0.2,
      'to_y': 0.5,
      'duration': 300,
    },
    'swipe_right': {
      'from_x': 0.2,
      'from_y': 0.5,
      'to_x': 0.8,
      'to_y': 0.5,
      'duration': 300,
    },
  };

  /// Perform gesture with preset or custom coordinates

  /// Cast an [AppDriver] to [FlutterSkillClient], throwing a clear error
  /// if the active connection is a bridge driver (non-Flutter).
  FlutterSkillClient _asFlutterClient(AppDriver driver, String toolName) {
    if (driver is FlutterSkillClient) return driver;
    throw Exception(
      '❌ "$toolName" requires a Flutter (VM Service) connection, '
      'but the active session uses the ${driver.frameworkName} bridge driver.\n'
      'This tool is not available for ${driver.frameworkName} apps.',
    );
  }

  void _requireConnection([AppDriver? client]) {
    client ??= _client;
    if (client == null) {
      throw Exception('''❌ Not connected to Flutter app.

📍 Current Status:
   • No active VM Service connection
   • Unable to interact with Flutter app

🔧 How to Connect:

   Option 1: Auto-detect Running App (Easiest)
   ───────────────────────────────────────────────
   scan_and_connect()
   → Automatically finds and connects to running Flutter apps on ports 50000-50100

   Option 2: Auto-launch App (Recommended)
   ───────────────────────────────────────────────
   launch_app(project_path: ".", device_id: "iPhone 16 Pro")
   → Starts app with VM Service enabled on port 50000

   Option 3: Manual Connect with URI
   ───────────────────────────────────────────────
   connect_app(uri: "ws://127.0.0.1:50000/abcd1234=/ws")
   → Connects to specific VM Service WebSocket URI

💡 Pro Tips:
   • Use get_connection_status() to see available running apps
   • Use list_sessions() to see all active connections
   • URI must start with "ws://" (WebSocket protocol)
   • Port 50000 is the default for flutter_skill

⚠️  Troubleshooting:
   • Ensure flutter_skill dependency is in your Flutter project
   • Verify FlutterSkillBinding.ensureInitialized() is called in main()
   • Run flutter with: --vm-service-port=50000 for consistent connections
''');
    }

    if (!client.isConnected) {
      // Connection lost - note: with multi-session, we don't clean up here
      throw Exception('''❌ Connection to Flutter app was lost.

📍 What Happened:
   • VM Service connection dropped
   • App may have crashed, restarted, or been terminated

🔧 How to Reconnect:

   Option 1: Auto-reconnect
   ───────────────────────────────────────────────
   scan_and_connect()
   → Automatically finds running Flutter apps

   Option 2: Reconnect with URI
   ───────────────────────────────────────────────
   connect_app(uri: "ws://...")
   → Use the same URI or check get_connection_status() for new URI

   Option 3: Restart App
   ───────────────────────────────────────────────
   launch_app(project_path: "...")
   → Launch a fresh instance

💡 Check Status:
   get_connection_status() → See all available running apps
''');
    }
  }

  /// Determine if an error should be auto-reported to GitHub
  bool _shouldReportError(dynamic error) {
    final errorStr = error.toString().toLowerCase();

    // Report these critical errors
    final criticalPatterns = [
      'lateinitializationerror',
      'null check operator',
      'unhandledexception',
      'stackoverflow',
      'outofmemory',
    ];

    // Don't report these expected errors
    final ignoredPatterns = [
      'not connected',
      'no isolates found',
      'connection refused',
      'timeout',
      'rpcerror', // errors from target app, not flutter-skill itself
      'server error', // RPC server errors from target app
    ];

    // Check if it's a critical error
    for (final pattern in criticalPatterns) {
      if (errorStr.contains(pattern)) {
        // Make sure it's not an ignored error
        for (final ignored in ignoredPatterns) {
          if (errorStr.contains(ignored)) return false;
        }
        return true;
      }
    }

    return false;
  }

  /// Scan for VM Services on local ports

  // ==================== End Build Error Helpers ====================

  void _sendNotification(String method, [Map<String, dynamic>? params]) {
    stdout.writeln(jsonEncode({
      "jsonrpc": "2.0",
      "method": method,
      if (params != null && params.isNotEmpty) "params": params,
    }));
  }

  void _sendResult(dynamic id, dynamic result) {
    if (id == null) return;
    stdout.writeln(jsonEncode({"jsonrpc": "2.0", "id": id, "result": result}));
  }

  /// Reports an error that occurred before a request id could be read.
  ///
  /// [_sendError] drops null ids so that notifications stay unanswered, but
  /// JSON-RPC 2.0 requires parse and invalid-request errors to be reported
  /// with a null id. Without this the client sees silence and treats the
  /// server as hung.
  void _sendProtocolError(int code, String message) {
    stdout.writeln(jsonEncode({
      "jsonrpc": "2.0",
      "id": null,
      "error": {"code": code, "message": message},
    }));
  }

  void _sendError(dynamic id, int code, String message) {
    if (id == null) return;
    stdout.writeln(jsonEncode({
      "jsonrpc": "2.0",
      "id": id,
      "error": {"code": code, "message": message},
    }));
  }

  /// Detect if iOS simulator or Android emulator is running
  /// Find adb binary, checking ANDROID_HOME and common paths

  /// Generate TOTP code (RFC 6238)

  /// Export recorded steps as Jest test
}

// ==================== CLI Error Formatting ====================

/// Print a structured, actionable CLI error to stderr.
void _printCliError(String title, String detail,
    {List<String> fixes = const []}) {
  stderr.writeln('');
  stderr.writeln('❌ $title');
  stderr.writeln('');
  stderr.writeln('   $detail');
  if (fixes.isNotEmpty) {
    stderr.writeln('');
    stderr.writeln('🔧 Suggested Fixes:');
    for (final fix in fixes) {
      stderr.writeln('   • $fix');
    }
  }
  stderr.writeln('');
}

// ==================== Lock Management ====================

/// Acquire a lock file to prevent multiple server instances
Future<File?> _acquireLock() async {
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  if (home == null) return null;

  final lockFile = File('$home/.flutter_skill.lock');

  // Check if lock exists and is stale (older than 10 minutes)
  if (await lockFile.exists()) {
    final stat = await lockFile.stat();
    final age = DateTime.now().difference(stat.modified);
    if (age.inMinutes < 10) {
      // Lock is fresh, another instance is likely running
      return null;
    }
    // Stale lock, remove it
    await lockFile.delete();
  }

  // Create lock file with current PID
  await lockFile.writeAsString('${pid}\n${DateTime.now().toIso8601String()}');
  return lockFile;
}

/// Release the lock file
Future<void> _releaseLock(File lockFile) async {
  try {
    if (await lockFile.exists()) {
      await lockFile.delete();
    }
  } catch (e) {
    // Ignore cleanup errors
  }
}

/// SkillEngine implementation that reads state directly from FlutterMcpServer.
/// Phase 1: thin wrapper. Phase 2+: logic moves here.
class _ServerSkillEngine implements SkillEngine {
  final FlutterMcpServer _server;
  _ServerSkillEngine(this._server);

  @override
  AppDriver? get client => _server._client;

  @override
  CdpDriver? get cdpDriver => _server._cdpDriver;

  @override
  bool get isConnected => _server._client != null || _server._cdpDriver != null;

  @override
  String? get connectionType {
    if (_server._cdpDriver != null) return 'cdp';
    if (_server._client is BridgeDriver) return 'bridge';
    if (_server._client is FlutterSkillClient) return 'flutter';
    return null;
  }

  @override
  List<Map<String, dynamic>> getAvailableTools({
    List<Map<String, dynamic>> pluginTools = const [],
  }) {
    return ToolRegistry.getFilteredTools(
      hasCdp: _server._cdpDriver != null,
      hasBridge: _server._client is BridgeDriver && _server._cdpDriver == null,
      hasFlutter: _server._client is FlutterSkillClient &&
          _server._client is! BridgeDriver,
      hasConnection: isConnected,
      pluginTools: pluginTools.isNotEmpty ? pluginTools : _server._pluginTools,
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
  Future<dynamic> executeTool(String name, Map<String, dynamic> args) {
    return _server._executeTool(name, args);
  }

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
  }) =>
      executeTool('connect_cdp', {
        'port': port,
        if (url != null) 'url': url,
        'launch_chrome': launchChrome,
        if (chromePath != null) 'chrome_path': chromePath,
        'headless': headless,
        if (proxy != null) 'proxy': proxy,
        'ignore_ssl': ignoreSsl,
        'max_tabs': maxTabs,
      });

  @override
  Future<void> connectBridge({String? host, int? port}) => executeTool(
      'scan_and_connect',
      {if (host != null) 'host': host, if (port != null) 'port': port});

  @override
  Future<void> connectFlutter({String? vmServiceUri}) => executeTool(
      'connect_app', {if (vmServiceUri != null) 'uri': vmServiceUri});

  @override
  Future<void> scanAndConnect() => executeTool('scan_and_connect', {});

  @override
  Future<void> disconnect() async {
    if (_server._cdpDriver != null) {
      await _server._cdpDriver!.disconnect();
      _server._cdpDriver = null;
    }
  }

  @override
  Future<void> dispose() async => disconnect();
}
