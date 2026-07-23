/// E2E test for the C++ bridge SDK — Dart side.
///
/// Verifies that BridgeDiscovery can find a running cpp_test_app and that
/// BridgeDriver can execute all core methods against it.
///
/// This exercises exactly the same code path as connect_app / scan_and_connect
/// in the MCP server, without needing to start the full server.
///
/// Usage:
///   dart run test/cpp_bridge_test.dart
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_skill/src/discovery/bridge_discovery.dart';
import 'package:flutter_skill/src/drivers/bridge_driver.dart';

const _port = 18118;
const _binary = 'test/e2e/cpp_test_app/build/cpp_test_app';

int _pass = 0, _fail = 0;

void record(String name, bool ok, [String detail = '']) {
  if (ok) _pass++; else _fail++;
  print('${ok ? '✅' : '❌'} $name${detail.isNotEmpty ? ' — $detail' : ''}');
}

Future<void> main() async {
  print('══════════════════════════════════════');
  print('C++ Bridge — Dart Integration Test');
  print('══════════════════════════════════════\n');

  // 1. Start the cpp_test_app
  final binary = File(_binary);
  if (!binary.existsSync()) {
    print('ERROR: binary not found at $_binary');
    print('Run: cd test/e2e/cpp_test_app && cmake -B build && cmake --build build');
    exit(1);
  }

  print('[setup] Starting cpp_test_app on port $_port…');
  final proc = await Process.start(
    binary.absolute.path,
    [_port.toString()],
    mode: ProcessStartMode.normal,
  );

  final ready = Completer<void>();
  proc.stdout.transform(utf8.decoder).listen((line) {
    stdout.write('[app] $line');
    if (line.contains('Bridge ready') && !ready.isCompleted) ready.complete();
  });
  proc.stderr.transform(utf8.decoder).listen((line) => stderr.write('[app] $line'));

  await ready.future.timeout(const Duration(seconds: 5),
      onTimeout: () => throw Exception('cpp_test_app did not start within 5s'));
  print('');

  try {
    // 2. BridgeDiscovery — health endpoint probe (the core fix)
    print('[test] BridgeDiscovery.discoverAll()…');
    final apps = await BridgeDiscovery.discoverAll(
      portStart: _port,
      portEnd: _port,
      verbose: true,
    );
    record('discovery_finds_cpp_app', apps.isNotEmpty,
        apps.isEmpty ? 'no apps found' : '${apps.length} app(s)');

    if (apps.isEmpty) {
      print('\nERROR: Discovery failed — HTTP health endpoint not working.');
      proc.kill();
      exit(1);
    }

    final info = apps.first;
    record('discovery_framework_cpp', info.framework == 'cpp',
        'framework: ${info.framework}');
    record('discovery_has_ws_uri', info.wsUri.isNotEmpty, info.wsUri);
    record('discovery_capabilities',
        info.capabilities.contains('screenshot') &&
            info.capabilities.contains('tap'),
        '${info.capabilities.length} caps');

    // 3. BridgeDriver — same driver used by connect_app after _probeBridgeUri
    print('\n[test] BridgeDriver.connect()…');
    final driver = BridgeDriver.fromInfo(info);
    await driver.connect();
    record('bridge_driver_connect', driver.isConnected);

    // Helper to call a bridge method and check the result
    Future<void> call(
      String method,
      Map<String, dynamic> params,
      String testName,
      bool Function(Map<String, dynamic>) check,
    ) async {
      try {
        final r = await driver.callMethod(method, params);
        final preview = r.toString();
        record(testName, check(r),
            preview.substring(0, preview.length.clamp(0, 80)));
      } catch (e) {
        final msg = e.toString();
        record(testName, false, msg.substring(0, msg.length.clamp(0, 80)));
      }
    }

    await call('initialize', {}, 'initialize',
        (r) => r['framework'] == 'cpp');
    await call('ping', {}, 'ping',
        (r) => r['pong'] == true);
    await call('screenshot', {}, 'screenshot',
        (r) => r.containsKey('screenshot') || r.containsKey('image') || r.containsKey('data'));
    await call('inspect', {}, 'inspect',
        (r) => r.containsKey('success') || r.containsKey('title'));
    await call('get_focused_window_title', {}, 'get_focused_window_title',
        (r) => r.isNotEmpty);
    await call('tap', {'x': 100, 'y': 100}, 'tap',
        (r) => r['success'] == true);
    await call('scroll', {'direction': 'down', 'amount': 100}, 'scroll',
        (r) => r['success'] == true);
    await call('enter_text', {'text': 'dart integration test'}, 'enter_text',
        (r) => r['success'] == true);
    await call('press_key', {'key': 'tab'}, 'press_key',
        (r) => r['success'] == true);
    await call('get_logs', {}, 'get_logs',
        (r) => r.containsKey('logs'));
    await call('clear_logs', {}, 'clear_logs',
        (r) => r['success'] == true);

    await driver.disconnect();

    // 4. Simulate connect_app URI probe (_probeBridgeUri equivalent).
    // The C++ bridge is single-client/synchronous, so the HTTP probe must run
    // after the WebSocket session closes (otherwise accept() is blocked).
    print('\n[test] connect_app URI probe (HTTP GET /.flutter-skill)…');
    await Future.delayed(const Duration(milliseconds: 100)); // let bridge re-enter accept()
    final httpClient = HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 300);
    final req = await httpClient.get('127.0.0.1', _port, '/.flutter-skill');
    final res = await req.close().timeout(const Duration(milliseconds: 500));
    final body = await res.transform(utf8.decoder).join();
    final json = jsonDecode(body) as Map<String, dynamic>;
    record('connect_app_probe_200', res.statusCode == 200,
        'HTTP ${res.statusCode}');
    record('connect_app_probe_framework', json['framework'] == 'cpp',
        'framework: ${json['framework']}');
    httpClient.close();

  } finally {
    proc.kill();
    await proc.exitCode;
  }

  print('\n══════════════════════════════════════');
  print('PASS: $_pass | FAIL: $_fail | TOTAL: ${_pass + _fail}');
  print('══════════════════════════════════════');
  if (_fail > 0) exit(1);
}
