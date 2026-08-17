import 'dart:async';
import 'dart:io';
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';
import '../discovery/unified_discovery.dart';
import 'app_driver.dart';

class FlutterSkillClient implements AppDriver {
  final String wsUri;
  VmService? _service;
  String? _isolateId;
  bool _reconnecting = false;

  /// Services registered on the VM by external clients (notably the Flutter
  /// tool, alias "Flutter Tools"), keyed by service name -> callable method
  /// (e.g. `reloadSources` -> `s1.reloadSources`). Populated from the
  /// `Service` stream, which replays existing registrations on subscribe.
  final Map<String, String> _registeredServices = {};
  final Map<String, Completer<String?>> _serviceWaiters = {};
  StreamSubscription<Event>? _serviceEvents;

  FlutterSkillClient(this.wsUri);

  /// Get the VM Service URI this client is connected to
  String get vmServiceUri => wsUri;

  Future<void> connect() async {
    print('DEBUG: Connecting to $wsUri');
    try {
      _service = await vmServiceConnectUri(wsUri);
      print('DEBUG: Connected to VM Service');

      final vm = await _service!.getVM();
      print('DEBUG: Got VM info');
      final isolates = vm.isolates;
      if (isolates == null || isolates.isEmpty) {
        throw Exception('''❌ No Dart isolates found in the VM

This usually means:
• App is still starting up (wait a few seconds and retry)
• App crashed during startup
• flutter_skill dependency is not properly initialized

Solution:
1. Wait 2-3 seconds and try again
2. Ensure FlutterSkillBinding.ensureInitialized() is called in main()
3. Check app logs for startup errors

URI: $wsUri''');
      }
      _isolateId = _pickMainIsolate(isolates);
      await _watchRegisteredServices();
    } catch (e) {
      // Clean up partially initialized service
      try {
        await _service?.dispose();
      } catch (_) {}
      _service = null;
      _isolateId = null;

      throw Exception('''❌ Failed to connect to VM Service at $wsUri

Possible causes:
• Invalid URI format (must start with ws://)
• App is not running or has crashed
• Wrong port number
• Network connectivity issues
• VM Service proxy failed to initialize (LateInitializationError)

Solution:
1. Verify the URI: $wsUri
2. Check if app is running: flutter run --vm-service-port=50000
3. Try scan_and_connect() to auto-detect running apps

Error details: $e''');
    }
  }

  Future<void> disconnect() async {
    await _serviceEvents?.cancel();
    _serviceEvents = null;
    _registeredServices.clear();
    _serviceWaiters.clear();
    try {
      await _service?.dispose();
    } catch (_) {
      // Ignore errors during disposal — service may already be broken
    }
    _service = null;
    _isolateId = null;
  }

  /// Check if an error indicates a broken VM Service connection that
  /// may be recoverable via reconnection.
  bool _isConnectionError(Object e) {
    final msg = e.toString();
    return msg.contains('LateInitializationError') ||
        (e is StateError && msg.contains('Stream'));
  }

  /// Attempt to re-establish the VM Service connection.
  /// Returns true if reconnection succeeded.
  Future<bool> _reconnect() async {
    if (_reconnecting) return false;
    _reconnecting = true;
    try {
      print(
          'DEBUG: VM Service connection lost, attempting reconnect to $wsUri');
      // Tear down the old connection
      try {
        await _service?.dispose();
      } catch (_) {}
      _service = null;
      _isolateId = null;

      // Re-establish
      _service = await vmServiceConnectUri(wsUri);
      final vm = await _service!.getVM();
      final isolates = vm.isolates;
      if (isolates != null && isolates.isNotEmpty) {
        _isolateId = _pickMainIsolate(isolates);
        await _watchRegisteredServices();
        print('DEBUG: Reconnected to VM Service successfully');
        return true;
      }
      // Connected but no isolates — app may have exited
      _service = null;
      return false;
    } catch (e) {
      print('DEBUG: Reconnection failed: $e');
      _service = null;
      _isolateId = null;
      return false;
    } finally {
      _reconnecting = false;
    }
  }

  Future<Map<String, dynamic>> _call(String method,
      [Map<String, dynamic>? args]) async {
    if (_service == null || _isolateId == null) {
      throw Exception('''❌ Not connected to VM Service

Call connect() first before making requests.
URI: $wsUri''');
    }
    try {
      final response = await _service!.callServiceExtension(
        method,
        isolateId: _isolateId!,
        args: args,
      );
      return response.json ?? {};
    } catch (e) {
      final msg = e.toString();
      // The cached isolate no longer exists (e.g. after a hot restart):
      // re-resolve the main isolate once and retry.
      if (_isStaleIsolateError(e) && await _refreshIsolate()) {
        final response = await _service!.callServiceExtension(
          method,
          isolateId: _isolateId!,
          args: args,
        );
        return response.json ?? {};
      }
      // Detect SDK-not-integrated errors and surface a clear setup message.
      if (msg.contains('Method not found') ||
          msg.contains('Service extension not found') ||
          msg.contains('ext.flutter.flutter_skill') && msg.contains('-32601')) {
        throw Exception('''❌ flutter_skill SDK not found in the running app.

The app is running but the flutter_skill extensions are not registered.

🔧 Fix:
1. Add dependency to pubspec.yaml:
   flutter pub add flutter_skill

2. Add to lib/main.dart BEFORE runApp():
   import 'package:flutter_skill/flutter_skill.dart';
   void main() {
     FlutterSkillBinding.ensureInitialized();
     runApp(MyApp());
   }

3. Hot restart the app (not just hot reload):
   flutter_skill hot_restart

Auto-setup: run  diagnose_project()  to fix automatically.
''');
      }
      if (!_isConnectionError(e)) rethrow;

      // Connection broken — attempt one reconnect and retry
      if (await _reconnect()) {
        final response = await _service!.callServiceExtension(
          method,
          isolateId: _isolateId!,
          args: args,
        );
        return response.json ?? {};
      }
      throw Exception('❌ VM Service connection lost and reconnection failed.\n'
          'URI: $wsUri\n'
          'Original error: $e\n\n'
          'Try: scan_and_connect() or connect_app(uri: "ws://...")');
    }
  }

  // ==================== EXISTING METHODS ====================

  /// Tap an element. Returns result with success status.
  /// Supports semantic ref IDs from inspect_interactive for reliable targeting.
  Future<Map<String, dynamic>> tap(
      {String? key, String? text, String? ref}) async {
    if (key == null && text == null && ref == null) {
      throw ArgumentError('Must provide key, text, or ref for tap');
    }
    final result = await _call('ext.flutter.flutter_skill.tap', {
      if (key != null) 'key': key,
      if (text != null) 'text': text,
      if (ref != null) 'ref': ref,
    });
    return result;
  }

  /// Enter text into a field. Returns result with success status.
  /// Supports semantic ref IDs from inspect_interactive for reliable targeting.
  Future<Map<String, dynamic>> enterText(String? key, String text,
      {String? ref}) async {
    final result = await _call('ext.flutter.flutter_skill.enterText', {
      if (key != null) 'key': key,
      'text': text,
      if (ref != null) 'ref': ref,
    });
    return result;
  }

  /// Scroll to element. Returns result with success status.
  Future<Map<String, dynamic>> scrollTo({String? key, String? text}) async {
    final result = await _call('ext.flutter.flutter_skill.scroll', {
      if (key != null) 'key': key,
      if (text != null) 'text': text,
    });
    return result;
  }

  // ==================== UI INSPECTION ====================

  Future<Map<String, dynamic>> getWidgetTree({int maxDepth = 10}) async {
    final result = await _call('ext.flutter.flutter_skill.getWidgetTree', {
      'maxDepth': maxDepth.toString(),
    });
    return result['tree'] ?? {};
  }

  Future<Map<String, dynamic>?> getWidgetProperties(String key) async {
    final result =
        await _call('ext.flutter.flutter_skill.getWidgetProperties', {
      'key': key,
    });
    return result['properties'];
  }

  Future<List<dynamic>> getTextContent() async {
    final result = await _call('ext.flutter.flutter_skill.getTextContent');
    return result['texts'] ?? [];
  }

  Future<List<dynamic>> findByType(String type) async {
    final result = await _call('ext.flutter.flutter_skill.findByType', {
      'type': type,
    });
    return result['elements'] ?? [];
  }

  // ==================== MORE INTERACTIONS ====================

  Future<bool> longPress(
      {String? key, String? text, int duration = 500}) async {
    final result = await _call('ext.flutter.flutter_skill.longPress', {
      if (key != null) 'key': key,
      if (text != null) 'text': text,
      'duration': duration.toString(),
    });
    return result['success'] == true;
  }

  Future<bool> swipe(
      {required String direction, double distance = 300, String? key}) async {
    final result = await _call('ext.flutter.flutter_skill.swipe', {
      'direction': direction,
      'distance': distance.toString(),
      if (key != null) 'key': key,
    });
    return result['success'] == true;
  }

  Future<bool> drag({required String fromKey, required String toKey}) async {
    final result = await _call('ext.flutter.flutter_skill.drag', {
      'fromKey': fromKey,
      'toKey': toKey,
    });
    return result['success'] == true;
  }

  Future<bool> doubleTap({String? key, String? text}) async {
    final result = await _call('ext.flutter.flutter_skill.doubleTap', {
      if (key != null) 'key': key,
      if (text != null) 'text': text,
    });
    return result['success'] == true;
  }

  /// Press a key by name in the running Flutter app via the VM Service extension.
  /// Supported keys: enter, tab, escape, backspace, delete, space, up, down,
  /// left, right, and any single character.
  Future<Map<String, dynamic>> pressKey(String key,
      {List<String>? modifiers}) async {
    return await _call('ext.flutter.flutter_skill.pressKey', {
      'key': key,
      if (modifiers != null && modifiers.isNotEmpty)
        'modifiers': modifiers.join(','),
    });
  }

  // ==================== STATE & VALIDATION ====================

  Future<String?> getTextValue(String? key) async {
    final result = await _call('ext.flutter.flutter_skill.getTextValue', {
      if (key != null) 'key': key,
    });
    return result['value'];
  }

  Future<bool?> getCheckboxState(String key) async {
    final result = await _call('ext.flutter.flutter_skill.getCheckboxState', {
      'key': key,
    });
    return result['checked'];
  }

  Future<double?> getSliderValue(String key) async {
    final result = await _call('ext.flutter.flutter_skill.getSliderValue', {
      'key': key,
    });
    return result['value']?.toDouble();
  }

  Future<bool> waitForElement(
      {String? key, String? text, int timeout = 5000}) async {
    final result = await _call('ext.flutter.flutter_skill.waitForElement', {
      if (key != null) 'key': key,
      if (text != null) 'text': text,
      'timeout': timeout.toString(),
    });
    return result['found'] == true;
  }

  Future<bool> waitForGone(
      {String? key, String? text, int timeout = 5000}) async {
    final result = await _call('ext.flutter.flutter_skill.waitForGone', {
      if (key != null) 'key': key,
      if (text != null) 'text': text,
      'timeout': timeout.toString(),
    });
    return result['gone'] == true;
  }

  // ==================== SCREENSHOT ====================

  Future<String?> takeScreenshot({double quality = 1.0, int? maxWidth}) async {
    final result = await _call('ext.flutter.flutter_skill.screenshot', {
      'quality': quality.toString(),
      if (maxWidth != null) 'maxWidth': maxWidth.toString(),
    });
    return result['image'];
  }

  Future<String?> takeRegionScreenshot(
      double x, double y, double width, double height) async {
    final result = await _call('ext.flutter.flutter_skill.screenshotRegion', {
      'x': x.toString(),
      'y': y.toString(),
      'width': width.toString(),
      'height': height.toString(),
    });
    return result['image'];
  }

  Future<String?> takeElementScreenshot(String key) async {
    final result = await _call('ext.flutter.flutter_skill.screenshotElement', {
      'key': key,
    });
    return result['image'];
  }

  // ==================== NAVIGATION ====================

  Future<String?> getCurrentRoute() async {
    final result = await _call('ext.flutter.flutter_skill.getCurrentRoute');
    return result['route'];
  }

  Future<bool> goBack() async {
    final result = await _call('ext.flutter.flutter_skill.goBack');
    return result['success'] == true;
  }

  Future<List<String>> getNavigationStack() async {
    final result = await _call('ext.flutter.flutter_skill.getNavigationStack');
    return (result['stack'] as List?)?.cast<String>() ?? [];
  }

  // ==================== DEBUG & LOGS ====================

  Future<List<String>> getLogs() async {
    final result = await _call('ext.flutter.flutter_skill.getLogs');
    return (result['logs'] as List?)?.cast<String>() ?? [];
  }

  Future<List<dynamic>> getErrors() async {
    final result = await _call('ext.flutter.flutter_skill.getErrors');
    return result['errors'] ?? [];
  }

  Future<void> clearLogs() async {
    await _call('ext.flutter.flutter_skill.clearLogs');
  }

  Future<Map<String, dynamic>> getPerformance() async {
    return await _call('ext.flutter.flutter_skill.getPerformance');
  }

  // ==================== COORDINATE-BASED ACTIONS ====================

  Future<Map<String, dynamic>> tapAt(double x, double y) async {
    return await _call('ext.flutter.flutter_skill.tapAt', {
      'x': x.toString(),
      'y': y.toString(),
    });
  }

  Future<Map<String, dynamic>> longPressAt(double x, double y,
      {int duration = 500}) async {
    return await _call('ext.flutter.flutter_skill.longPressAt', {
      'x': x.toString(),
      'y': y.toString(),
      'duration': duration.toString(),
    });
  }

  Future<Map<String, dynamic>> swipeCoordinates(
    double startX,
    double startY,
    double endX,
    double endY, {
    int duration = 300,
  }) async {
    return await _call('ext.flutter.flutter_skill.swipeCoordinates', {
      'startX': startX.toString(),
      'startY': startY.toString(),
      'endX': endX.toString(),
      'endY': endY.toString(),
      'duration': duration.toString(),
    });
  }

  /// Edge swipe from screen edge
  Future<Map<String, dynamic>> edgeSwipe({
    required String edge, // left, right, top, bottom
    required String direction, // up, down, left, right
    double distance = 200,
  }) async {
    return await _call('ext.flutter.flutter_skill.edgeSwipe', {
      'edge': edge,
      'direction': direction,
      'distance': distance.toString(),
    });
  }

  // ==================== PERFORMANCE & MEMORY ====================

  Future<Map<String, dynamic>> getFrameStats() async {
    try {
      final result = await _call('ext.flutter.flutter_skill.getFrameStats');
      return result;
    } catch (e) {
      // Fallback to basic stats if extension not available
      return {
        "message":
            "Frame stats not available. Ensure flutter_skill is properly initialized in the app.",
        "error": e.toString(),
      };
    }
  }

  Future<Map<String, dynamic>> getMemoryStats() async {
    if (_service == null || _isolateId == null) {
      throw Exception('Not connected to Flutter app');
    }

    try {
      final allocationProfile =
          await _service!.getAllocationProfile(_isolateId!);
      return {
        "heapUsed": allocationProfile.memoryUsage?.heapUsage ?? 0,
        "heapCapacity": allocationProfile.memoryUsage?.heapCapacity ?? 0,
        "external": allocationProfile.memoryUsage?.externalUsage ?? 0,
      };
    } catch (e) {
      // getAllocationProfile not available on web VM
      if (e.toString().contains('Unknown method') ||
          e.toString().contains('-32601')) {
        return {
          "heapUsed": 0,
          "heapCapacity": 0,
          "external": 0,
          "message": "Memory stats not available on this platform",
        };
      }
      if (!_isConnectionError(e)) rethrow;
      if (await _reconnect()) {
        final allocationProfile =
            await _service!.getAllocationProfile(_isolateId!);
        return {
          "heapUsed": allocationProfile.memoryUsage?.heapUsage ?? 0,
          "heapCapacity": allocationProfile.memoryUsage?.heapCapacity ?? 0,
          "external": allocationProfile.memoryUsage?.externalUsage ?? 0,
        };
      }
      throw Exception('❌ VM Service connection lost and reconnection failed.\n'
          'URI: $wsUri\n'
          'Original error: $e');
    }
  }

  // ==================== ENHANCED INSPECTION ====================

  Future<List<dynamic>> getInteractiveElements(
      {bool includePositions = true}) async {
    final result = await _call('ext.flutter.flutter_skill.interactive', {
      'includePositions': includePositions.toString(),
    });

    if (result.containsKey('elements')) {
      return result['elements'] as List<dynamic>;
    }
    return [];
  }

  /// Get interactive elements with enhanced structure including actions and selectors
  Future<Map<String, dynamic>> getInteractiveElementsStructured() async {
    final result =
        await _call('ext.flutter.flutter_skill.interactiveStructured');

    if (result.containsKey('data')) {
      return result['data'] as Map<String, dynamic>;
    }

    // Return empty structured result if no data
    return {
      'elements': <Map<String, dynamic>>[],
      'summary': 'No interactive elements found',
    };
  }

  // ==================== EXISTING HELPERS ====================

  // ==================== HOT RELOAD / RESTART ====================
  //
  // A Flutter app cannot recompile Dart source on its own: the engine ships
  // no kernel compiler, so the VM's built-in `reloadSources` RPC fails with
  // "Error while starting Kernel isolate task" (and hot restart has no VM
  // RPC at all). The `flutter run` tool that launched the app owns the
  // incremental compiler and registers `reloadSources` and `hotRestart` as
  // VM *services* (alias "Flutter Tools"); invoking those — exactly what
  // DevTools and the IDEs do — recompiles, reloads and reassembles.

  static const _reloadService = 'reloadSources';
  static const _restartService = 'hotRestart';

  /// Hot reload through the Flutter tool. Returns a short human report.
  Future<String> hotReload() async {
    _requireService();
    final elapsed = await _invokeFlutterTools(_reloadService);
    if (elapsed != null) {
      await _settleCompileClock();
      return 'Hot reload performed by Flutter Tools (${elapsed}ms)';
    }
    // No Flutter tool attached: the raw VM RPC is the only option. It only
    // succeeds when the VM can compile Dart itself (plain `dart run`), so
    // check the report instead of silently claiming success.
    final report =
        await _callWithReconnect(() => _service!.reloadSources(_isolateId!));
    if (report.success == true) return 'Hot reload performed by the VM';
    // `notices` is not modelled by package:vm_service; read the raw JSON.
    final notices = report.json?['notices'] as List<dynamic>? ?? const [];
    final reasons = notices
        .map((n) => (n as Map<String, dynamic>?)?['message'])
        .whereType<String>()
        .join('; ');
    throw Exception('''❌ Hot reload is not possible on this VM Service.

The VM cannot recompile Dart sources ($reasons) and no `flutter run` tool
is attached to do it (no `reloadSources` service registered).

Fix: launch the app with `flutter run` (debug mode) and connect to the VM
Service URI it prints — the tool then registers the reload service that
this command drives.''');
  }

  /// Hot restart through the Flutter tool, then re-bind to the new isolate.
  Future<String> hotRestart() async {
    _requireService();
    final elapsed = await _invokeFlutterTools(_restartService);
    if (elapsed == null) {
      throw UnsupportedError(
          '''❌ Hot restart is not possible on this VM Service.

Hot restart is performed by the `flutter run` tool, which registers a
`hotRestart` service on the VM. None is registered here — the app was not
launched by `flutter run` in debug mode (or the tool has exited).

Fix: launch the app with `flutter run` and connect to the printed URI.''');
    }
    // The main isolate is recreated by the restart; rebind before returning
    // so the next call does not hit a collected isolate.
    if (!await _refreshIsolate()) {
      throw Exception('Hot restart completed but the new main isolate did '
          'not appear; reconnect with connect_app().');
    }
    final ready = await _awaitFirstFrame();
    await _settleCompileClock();
    return 'Hot restart performed by Flutter Tools (${elapsed}ms'
        '${ready ? '' : ', first frame not yet sent'})';
  }

  /// Invokes a service registered by the Flutter tool on the main isolate.
  /// Returns the elapsed milliseconds, or null when the tool has not
  /// registered [service] (no `flutter run` attached to this VM).
  Future<int?> _invokeFlutterTools(String service) async {
    final method = await _flutterToolsMethod(service);
    if (method == null) return null;
    final sw = Stopwatch()..start();
    await _callWithReconnect(
        () => _service!.callMethod(method, isolateId: _isolateId));
    return sw.elapsedMilliseconds;
  }

  /// Waits until the restarted app has built and sent its first frame, so
  /// the widget tree is populated for the caller's next inspection.
  /// (`didSendFirstFrameEvent` rather than the *Rasterized* variant: the
  /// latter never flips on some desktop embedders, e.g. Windows.)
  Future<bool> _awaitFirstFrame() async {
    const ext = 'ext.flutter.didSendFirstFrameEvent';
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      try {
        final response =
            await _service!.callServiceExtension(ext, isolateId: _isolateId);
        final enabled = response.json?['enabled'];
        if (enabled == true || enabled == 'true') return true;
      } catch (_) {
        // extension not registered yet — the isolate is still booting
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return false;
  }

  /// The Flutter tool detects edited files by comparing their mtime with the
  /// wall-clock time of its last compile. On Windows, Dart reports mtimes
  /// truncated to whole seconds, so a file saved within the same second as
  /// that compile is silently treated as unchanged by the next reload or
  /// restart ("0 updated files"). Agents edit and reload back-to-back, so
  /// return only once the clock has rolled past the second in which the
  /// compile happened; every later edit is then guaranteed to be picked up.
  Future<void> _settleCompileClock() async {
    if (!Platform.isWindows) return;
    final now = DateTime.now();
    final nextSecond = DateTime(
        now.year, now.month, now.day, now.hour, now.minute, now.second + 1);
    await Future<void>.delayed(nextSecond.difference(now));
  }

  void _requireService() {
    if (_service == null || _isolateId == null) {
      throw Exception('Not connected');
    }
  }

  Future<T> _callWithReconnect<T>(Future<T> Function() call) async {
    try {
      return await call();
    } catch (e) {
      if (!_isConnectionError(e)) rethrow;
      if (await _reconnect()) return await call();
      throw Exception('❌ VM Service connection lost and reconnection failed.\n'
          'URI: $wsUri\n'
          'Original error: $e');
    }
  }

  /// Subscribes to the `Service` stream so registered services (and their
  /// callable method names) are tracked live. The VM replays existing
  /// registrations right after `streamListen`.
  Future<void> _watchRegisteredServices() async {
    await _serviceEvents?.cancel();
    _registeredServices.clear();
    final service = _service;
    if (service == null) return;
    _serviceEvents = service.onServiceEvent.listen((event) {
      final name = event.service;
      if (name == null) return;
      if (event.kind == EventKind.kServiceRegistered && event.method != null) {
        _registeredServices[name] = event.method!;
        _serviceWaiters.remove(name)?.complete(event.method);
      } else if (event.kind == EventKind.kServiceUnregistered) {
        _registeredServices.remove(name);
      }
    });
    try {
      await service.streamListen(EventStreams.kService);
    } on RPCError catch (e) {
      // 103 = stream already subscribed; anything else is non-fatal here.
      if (e.code != 103) print('DEBUG: Service stream unavailable: $e');
    }
  }

  /// Method name (`sN.<service>`) for a service registered by the Flutter
  /// tool. Registrations replayed by the VM arrive asynchronously right after
  /// subscribing, so wait for the event (bounded) rather than polling.
  Future<String?> _flutterToolsMethod(String service) async {
    if (_serviceEvents == null) await _watchRegisteredServices();
    final known = _registeredServices[service];
    if (known != null) return known;
    final waiter =
        _serviceWaiters.putIfAbsent(service, () => Completer<String?>());
    return waiter.future.timeout(const Duration(seconds: 2), onTimeout: () {
      _serviceWaiters.remove(service);
      return null;
    });
  }

  static String _pickMainIsolate(List<IsolateRef> isolates) => isolates
      .firstWhere((i) => i.name == 'main', orElse: () => isolates.first)
      .id!;

  /// True when a call failed because the target isolate no longer exists
  /// (the VM answers with a `Collected`/`Expired` sentinel).
  bool _isStaleIsolateError(Object e) =>
      e is SentinelException ||
      // Some transports surface the sentinel only as a message.
      e.toString().contains('Sentinel kind: Collected');

  /// Re-binds to the recreated main isolate (hot restart, or a Sentinel from
  /// a call). The previous isolate may still be listed while it tears down,
  /// so only an isolate with a *different* id that is already runnable is
  /// accepted; polls briefly because the new one may not be up yet.
  Future<bool> _refreshIsolate() async {
    final service = _service;
    if (service == null) return false;
    final previous = _isolateId;
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      try {
        final candidates = ((await service.getVM()).isolates ?? const [])
            .where((i) => i.id != previous)
            .toList();
        if (candidates.isNotEmpty) {
          final id = _pickMainIsolate(candidates);
          if ((await service.getIsolate(id)).runnable == true) {
            _isolateId = id;
            return true;
          }
        }
      } catch (_) {
        // transient during restart
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return false;
  }

  Future<Map<String, dynamic>> getLayoutTree() async {
    try {
      final groupName =
          'flutter_skill_${DateTime.now().millisecondsSinceEpoch}';
      final result =
          await _call('ext.flutter.inspector.getRootWidgetSummaryTree', {
        'objectGroup': groupName,
      });
      return result;
    } catch (e) {
      rethrow;
    }
  }

  bool get isConnected => _service != null && _isolateId != null;

  @override
  String get frameworkName => 'Flutter';

  static Future<String> resolveUri(List<String> args) async {
    // 1. If URI provided as argument, use it directly
    if (args.isNotEmpty) {
      final arg = args[0];
      if (arg.startsWith('ws://') || arg.startsWith('http://')) {
        return arg;
      }
    }

    // 2. Try automatic discovery (fast and smart!)
    print('🔍 Auto-discovering running Flutter apps...');

    try {
      final result = await UnifiedDiscovery.discover(verbose: false);

      if (result.success && result.vmServiceUri != null) {
        // Convert http:// to ws:// if needed
        var uri = result.vmServiceUri!;
        if (uri.startsWith('http://')) {
          uri = uri.replaceFirst('http://', 'ws://');
          if (!uri.endsWith('/ws')) {
            uri = '$uri/ws';
          }
        }
        print('✅ Connected: $uri');
        return uri;
      }
    } catch (e) {
      print('⚠️  Auto-discovery failed: $e');
    }

    // 3. All methods failed
    throw ArgumentError('\n❌ No running Flutter apps found\n\n'
        'Please try:\n'
        '  1. Launch app: flutter_skill launch -d <device>\n'
        '  2. Or manually: flutter run -d <device>\n'
        '  3. Or provide URI: flutter_skill inspect ws://...\n');
  }

  // ==================== TEST INDICATORS ====================

  /// Enable test indicators with optional style
  Future<Map<String, dynamic>> enableTestIndicators(
      {String style = 'standard'}) async {
    return await _call('ext.flutter.flutter_skill.enableIndicators', {
      'style': style,
    });
  }

  /// Disable test indicators
  Future<Map<String, dynamic>> disableTestIndicators() async {
    return await _call('ext.flutter.flutter_skill.disableIndicators');
  }

  /// Get indicator status
  Future<Map<String, dynamic>> getIndicatorStatus() async {
    return await _call('ext.flutter.flutter_skill.getIndicatorStatus');
  }

  // ==================== HTTP MONITORING ====================

  /// Enable HTTP timeline logging via VM Service
  Future<bool> enableHttpTimelineLogging({bool enable = true}) async {
    try {
      await _service!.callServiceExtension(
        'ext.dart.io.httpEnableTimelineLogging',
        isolateId: _isolateId,
        args: {'enabled': enable},
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Get HTTP profile from VM Service (built-in Dart HTTP profiling)
  Future<Map<String, dynamic>> getHttpProfile() async {
    try {
      final response = await _service!.callServiceExtension(
        'ext.dart.io.getHttpProfile',
        isolateId: _isolateId,
      );
      return response.json ?? {};
    } catch (e) {
      return {'error': e.toString()};
    }
  }

  /// Get HTTP request details from VM Service
  Future<Map<String, dynamic>> getHttpProfileRequest(int id) async {
    try {
      final response = await _service!.callServiceExtension(
        'ext.dart.io.getHttpProfileRequest',
        isolateId: _isolateId,
        args: {'id': id},
      );
      return response.json ?? {};
    } catch (e) {
      return {'error': e.toString()};
    }
  }

  /// Get manually logged HTTP requests from the app
  Future<Map<String, dynamic>> getHttpRequests(
      {int limit = 50, int offset = 0}) async {
    return await _call('ext.flutter.flutter_skill.getHttpRequests', {
      'limit': limit.toString(),
      'offset': offset.toString(),
    });
  }

  /// Clear manually logged HTTP requests
  Future<Map<String, dynamic>> clearHttpRequests() async {
    return await _call('ext.flutter.flutter_skill.clearHttpRequests');
  }
}
