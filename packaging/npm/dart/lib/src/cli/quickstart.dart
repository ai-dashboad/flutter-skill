import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter_skill/src/cli/explore.dart' show runExplore;
import 'package:flutter_skill/src/cli/monkey.dart' show runMonkey;
import 'package:flutter_skill/src/cli/security.dart' show runSecurity;
import 'package:flutter_skill/src/cli/plan.dart' show runPlan;
import 'package:flutter_skill/src/cli/diff.dart' show runDiff;
import 'package:flutter_skill/src/bridge/cdp_driver.dart';

/// Detected project platform.
enum _Platform {
  webCdp,
  webSdk,
  flutter,
  electron,
  reactNative,
  tauri,
  maui,
  kmp,
  unknown,
}

/// Run a quick guided demo to showcase flutter-skill capabilities.
Future<void> runQuickstart(List<String> args) async {
  String? url;
  String? platformOverride;

  for (final arg in args) {
    if (arg.startsWith('--platform=')) {
      platformOverride = arg.substring(11);
    } else if (!arg.startsWith('-')) {
      url = arg;
    }
  }

  print('');
  print('🚀 flutter-skill quickstart');
  print('═══════════════════════════════════════════════════════════');
  print('');

  if (url != null) {
    await _quickstartWithUrl(url);
    return;
  }

  if (platformOverride != null) {
    final platform = _parsePlatform(platformOverride);
    if (platform == _Platform.unknown) {
      print('  ❌ Unknown platform: $platformOverride');
      print(
          '  Available: web, web-sdk, flutter, electron, react-native, tauri, maui, kmp');
      return;
    }
    await _runPlatformQuickstart(platform);
    return;
  }

  // Auto-detect platform from current directory
  final detected = _detectPlatform(Directory.current.path);
  if (detected != _Platform.unknown) {
    await _runPlatformQuickstart(detected);
  } else {
    // Default: web CDP demo
    await _runPlatformQuickstart(_Platform.webCdp);
  }
}

// ─── Platform Detection ──────────────────────────────────────────

_Platform _parsePlatform(String s) {
  switch (s.toLowerCase()) {
    case 'web':
    case 'web-cdp':
    case 'cdp':
      return _Platform.webCdp;
    case 'web-sdk':
    case 'sdk':
      return _Platform.webSdk;
    case 'flutter':
      return _Platform.flutter;
    case 'electron':
      return _Platform.electron;
    case 'react-native':
    case 'rn':
      return _Platform.reactNative;
    case 'tauri':
      return _Platform.tauri;
    case 'maui':
    case 'dotnet-maui':
      return _Platform.maui;
    case 'kmp':
    case 'kotlin':
      return _Platform.kmp;
    default:
      return _Platform.unknown;
  }
}

_Platform _detectPlatform(String dir) {
  // Flutter: pubspec.yaml with flutter dependency
  final pubspec = File('$dir/pubspec.yaml');
  if (pubspec.existsSync()) {
    final content = pubspec.readAsStringSync();
    if (content.contains('flutter:') || content.contains('flutter_test:')) {
      return _Platform.flutter;
    }
  }

  final packageJson = File('$dir/package.json');
  if (packageJson.existsSync()) {
    final content = packageJson.readAsStringSync();
    if (content.contains('"react-native"')) return _Platform.reactNative;
    if (content.contains('"electron"')) return _Platform.electron;
    // Generic web project
    return _Platform.webCdp;
  }

  // Tauri: Cargo.toml + tauri in src-tauri
  if (File('$dir/src-tauri/Cargo.toml').existsSync() ||
      (File('$dir/Cargo.toml').existsSync() &&
          File('$dir/Cargo.toml').readAsStringSync().contains('tauri'))) {
    return _Platform.tauri;
  }

  // .NET MAUI: .csproj with Maui
  final csprojFiles =
      Directory(dir).listSync().where((f) => f.path.endsWith('.csproj'));
  for (final f in csprojFiles) {
    if (File(f.path).readAsStringSync().contains('Maui')) {
      return _Platform.maui;
    }
  }

  // KMP: build.gradle.kts with multiplatform
  final gradle = File('$dir/build.gradle.kts');
  if (gradle.existsSync()) {
    final content = gradle.readAsStringSync();
    if (content.contains('multiplatform') ||
        content.contains('KotlinMultiplatform')) {
      return _Platform.kmp;
    }
  }

  return _Platform.unknown;
}

String _platformLabel(_Platform p) {
  switch (p) {
    case _Platform.webCdp:
      return '🌐 Web (CDP)';
    case _Platform.webSdk:
      return '🌐 Web (SDK)';
    case _Platform.flutter:
      return '🐦 Flutter (Dart)';
    case _Platform.electron:
      return '⚡ Electron';
    case _Platform.reactNative:
      return '⚛️  React Native';
    case _Platform.tauri:
      return '🦀 Tauri';
    case _Platform.maui:
      return '🟣 .NET MAUI';
    case _Platform.kmp:
      return '🟠 Kotlin Multiplatform';
    case _Platform.unknown:
      return '❓ Unknown';
  }
}

// ─── Platform Router ─────────────────────────────────────────────

Future<void> _runPlatformQuickstart(_Platform platform) async {
  print('  Detected: ${_platformLabel(platform)}');
  print('');

  switch (platform) {
    case _Platform.webCdp:
      await _quickstartWebCdp();
      break;
    case _Platform.webSdk:
      await _quickstartWebSdk();
      break;
    case _Platform.flutter:
      await _quickstartFlutter();
      break;
    case _Platform.electron:
      await _quickstartElectron();
      break;
    case _Platform.reactNative:
      _quickstartReactNativeGuide();
      break;
    case _Platform.tauri:
      _quickstartTauriGuide();
      break;
    case _Platform.maui:
      _quickstartMauiGuide();
      break;
    case _Platform.kmp:
      _quickstartKmpGuide();
      break;
    case _Platform.unknown:
      await _quickstartWebCdp();
      break;
  }
}

// ─── URL-based quickstart ────────────────────────────────────────

Future<void> _quickstartWithUrl(String url) async {
  print('  Target: $url');
  print('');

  await _runFullDemo(url);
  _printSummary(url);
}

// ─── Web CDP Quickstart ──────────────────────────────────────────

Future<void> _quickstartWebCdp() async {
  print('  No URL provided — launching built-in demo app...');
  print('');

  final tempDir = await Directory.systemTemp.createTemp('flutter-skill-demo-');
  final htmlFile = File('${tempDir.path}/index.html');
  await htmlFile.writeAsString(_demoHtml);

  HttpServer? server;
  try {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;
    final demoUrl = 'http://localhost:$port';

    print('  ✅ Demo app running at $demoUrl');
    print('');

    _serveStatic(server, tempDir.path);

    await _runFullDemo(demoUrl);
    _printSummary(demoUrl);
  } catch (e) {
    print('  ❌ Could not start demo server: $e');
  } finally {
    await server?.close(force: true);
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  }
}

// ─── Web SDK Quickstart ──────────────────────────────────────────

Future<void> _quickstartWebSdk() async {
  print('  Launching demo app with flutter-skill SDK injected...');
  print('');

  final tempDir =
      await Directory.systemTemp.createTemp('flutter-skill-sdk-demo-');
  final htmlFile = File('${tempDir.path}/index.html');
  await htmlFile.writeAsString(_demoHtmlWithSdk);

  HttpServer? server;
  try {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;
    final demoUrl = 'http://localhost:$port';

    print('  ✅ Demo app (with SDK) running at $demoUrl');
    print('');

    _serveStatic(server, tempDir.path);

    await _runFullDemo(demoUrl);
    _printSdkSummary(demoUrl);
  } catch (e) {
    print('  ❌ Could not start demo server: $e');
  } finally {
    await server?.close(force: true);
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  }
}

// ─── Flutter Quickstart ──────────────────────────────────────────

Future<void> _quickstartFlutter() async {
  // Prerequisites
  print('  ── Prerequisites ──');

  final flutterCmd = await _findFlutter();
  if (flutterCmd == null) {
    print('    ❌ Flutter SDK not found. Install from https://flutter.dev');
    return;
  }
  final flutterVersion = await _checkCommand(flutterCmd, ['--version']);
  final versionLine = (flutterVersion ?? 'unknown').split('\n').first;
  print('    ✅ Flutter SDK: $versionLine');

  final chromeCheck = await _findChrome();
  if (chromeCheck == null) {
    print('    ❌ Chrome not found. Required for Flutter web demo.');
    return;
  }
  print('    ✅ Chrome: available');
  print('');

  // Create temp Flutter project
  print('  ── Setting up demo ──');
  final tempDir = await Directory.systemTemp.createTemp('flutter-skill-demo-');
  final projectDir = '${tempDir.path}/demo_app';
  Process? flutterProcess;

  try {
    print('    Creating Flutter web app...');
    final createResult = await Process.run(
      flutterCmd,
      ['create', '--template=app', '--platforms=web', projectDir],
    );
    if (createResult.exitCode != 0) {
      print('    ❌ Failed to create Flutter project: ${createResult.stderr}');
      return;
    }

    // Inject a simple test-friendly main.dart
    final mainDart = File('$projectDir/lib/main.dart');
    await mainDart.writeAsString(_flutterDemoMain);

    // Run flutter pub get
    print('    Installing dependencies...');
    final pubGet = await Process.run(flutterCmd, ['pub', 'get'],
        workingDirectory: projectDir);
    if (pubGet.exitCode != 0) {
      print('    ❌ flutter pub get failed: ${pubGet.stderr}');
      return;
    }

    // Pick a random port
    final webPort = 10000 + Random().nextInt(50000);

    print('    Starting Flutter web app on port $webPort...');
    flutterProcess = await Process.start(
      flutterCmd,
      ['run', '-d', 'chrome', '--web-port=$webPort'],
      workingDirectory: projectDir,
    );

    // Pipe output so user can see Flutter startup progress
    flutterProcess.stdout
        .transform(const SystemEncoding().decoder)
        .listen((data) => stdout.write('    $data'));
    flutterProcess.stderr
        .transform(const SystemEncoding().decoder)
        .listen((data) => stderr.write('    $data'));

    // Wait for app to be ready by polling the web port
    final appUrl = 'http://localhost:$webPort';
    final ready = await _waitForHttpReady(webPort, timeoutSeconds: 120);
    if (!ready) {
      print(
          '    ❌ Flutter app failed to start (timeout waiting for port $webPort)');
      return;
    }

    print('    ✅ App running at $appUrl');
    print('');

    await _runFullDemo(appUrl);
    _printFlutterSummary(appUrl);
  } catch (e) {
    print('  ❌ Flutter quickstart failed: $e');
  } finally {
    flutterProcess?.kill();
    // Send 'q' to flutter run to quit gracefully
    try {
      flutterProcess?.stdin.write('q');
    } catch (_) {}
    await Future.delayed(const Duration(seconds: 1));
    flutterProcess?.kill(ProcessSignal.sigkill);
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  }
}

Future<bool> _waitForHttpReady(int port, {int timeoutSeconds = 120}) async {
  for (var i = 0; i < timeoutSeconds * 2; i++) {
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(milliseconds: 300);
      final request = await client.getUrl(Uri.parse('http://localhost:$port'));
      final response = await request.close();
      await response.drain<void>();
      client.close();
      if (response.statusCode < 500) return true;
    } catch (_) {}
    await Future.delayed(const Duration(milliseconds: 500));
  }
  return false;
}

// ─── Electron Quickstart ─────────────────────────────────────────

Future<void> _quickstartElectron() async {
  print('  ── Prerequisites ──');

  final nodeVersion = await _checkCommand('node', ['--version']);
  if (nodeVersion == null) {
    print('    ❌ Node.js not found. Install from https://nodejs.org');
    return;
  }
  print('    ✅ Node.js: ${nodeVersion.trim()}');

  final npmVersion = await _checkCommand('npm', ['--version']);
  if (npmVersion == null) {
    print('    ❌ npm not found.');
    return;
  }
  print('    ✅ npm: ${npmVersion.trim()}');
  print('');

  print('  ── Setting up demo ──');
  final tempDir =
      await Directory.systemTemp.createTemp('flutter-skill-electron-demo-');
  Process? electronProcess;
  HttpServer? demoServer;

  try {
    // Start HTTP server for the demo HTML first
    demoServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final serverPort = demoServer.port;
    final demoUrl = 'http://localhost:$serverPort';

    // Write demo HTML
    await File('${tempDir.path}/index.html').writeAsString(_demoHtml);
    _serveStatic(demoServer, tempDir.path);

    // Write Electron app that loads the same demo URL
    await File('${tempDir.path}/package.json').writeAsString('''{
  "name": "flutter-skill-electron-demo",
  "version": "1.0.0",
  "main": "main.js"
}''');

    await File('${tempDir.path}/main.js')
        .writeAsString(_electronMainJs(serverPort));

    print('    Installing Electron...');
    final npmInstall = await Process.run(
      'npm',
      ['install', 'electron', '--save-dev'],
      workingDirectory: tempDir.path,
    );
    if (npmInstall.exitCode != 0) {
      print('    ❌ npm install electron failed: ${npmInstall.stderr}');
      return;
    }

    print('    Starting Electron app...');
    electronProcess = await Process.start(
      'npx',
      ['electron', '.'],
      workingDirectory: tempDir.path,
    );

    // Give Electron a moment to launch
    await Future.delayed(const Duration(seconds: 2));
    print('    ✅ Electron app running with demo at $demoUrl');
    print('');

    // Test using standard Web CDP against the same URL
    await _runFullDemo(demoUrl);
    _printElectronSummary(serverPort);
  } catch (e) {
    print('  ❌ Electron quickstart failed: $e');
  } finally {
    electronProcess?.kill();
    await Future.delayed(const Duration(milliseconds: 500));
    electronProcess?.kill(ProcessSignal.sigkill);
    await demoServer?.close(force: true);
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  }
}

// ─── React Native Guide ──────────────────────────────────────────

void _quickstartReactNativeGuide() {
  final isRnProject =
      File('${Directory.current.path}/package.json').existsSync() &&
          File('${Directory.current.path}/package.json')
              .readAsStringSync()
              .contains('"react-native"');

  if (isRnProject) {
    print('  📱 React Native project detected!');
    print('');
    print('  React Native requires a running dev server. Follow these steps:');
    print('');
    print('  1. Start your dev server:');
    print('     npx react-native start');
    print('');
    print('  2. Run on a device/emulator:');
    print('     npx react-native run-android  # or run-ios');
    print('');
    print('  3. Enable remote debugging in the app (shake → Debug)');
    print('');
    print('  4. Run flutter-skill against the debug URL:');
    print('     flutter-skill explore http://localhost:8081');
    print('     flutter-skill monkey http://localhost:8081');
  } else {
    print('  ⚠️  Not inside a React Native project.');
    print('');
    print('  Run inside a React Native project directory, or use:');
    print('     flutter-skill quickstart <url>');
  }

  _printGuideFooter();
}

// ─── Tauri Guide ─────────────────────────────────────────────────

void _quickstartTauriGuide() {
  final isTauriProject =
      File('${Directory.current.path}/src-tauri/Cargo.toml').existsSync();

  if (isTauriProject) {
    print('  🦀 Tauri project detected!');
    print('');
    print('  Tauri uses a webview with remote debugging. Follow these steps:');
    print('');
    print('  1. Start Tauri in dev mode:');
    print('     cargo tauri dev');
    print('');
    print('  2. Find the debug port (check console output for DevTools URL)');
    print('');
    print('  3. Run flutter-skill:');
    print('     flutter-skill explore http://localhost:<port>');
    print('     flutter-skill monkey http://localhost:<port>');
  } else {
    print('  ⚠️  Not inside a Tauri project.');
    print('');
    print('  Run inside a Tauri project directory, or use:');
    print('     flutter-skill quickstart <url>');
  }

  _printGuideFooter();
}

// ─── .NET MAUI Guide ─────────────────────────────────────────────

void _quickstartMauiGuide() {
  print('  🟣 .NET MAUI — Guide Mode');
  print('');
  print('  MAUI apps require Visual Studio to build. Quickstart cannot');
  print('  scaffold automatically, but here\'s how to test your app:');
  print('');
  print('  1. Enable WebView remote debugging in your MAUI app:');
  print('     #if DEBUG');
  print('       webView.EnableWebDevTools = true;');
  print('     #endif');
  print('');
  print('  2. Build and run from Visual Studio');
  print('');
  print('  3. Find the Chrome DevTools port and run:');
  print('     flutter-skill explore http://localhost:<port>');
  print('     flutter-skill monkey http://localhost:<port>');
  print('');
  print('  For BlazorWebView apps, remote debugging is available');
  print('  on Android via chrome://inspect');

  _printGuideFooter();
}

// ─── KMP Guide ───────────────────────────────────────────────────

void _quickstartKmpGuide() {
  print('  🟠 Kotlin Multiplatform — Guide Mode');
  print('');
  print('  KMP apps require Android Studio or Xcode to build.');
  print('  Here\'s how to test your Compose Multiplatform web target:');
  print('');
  print('  1. Run the web (wasmJs) target:');
  print('     ./gradlew :composeApp:wasmJsBrowserDevelopmentRun');
  print('');
  print('  2. The dev server typically runs at http://localhost:8080');
  print('');
  print('  3. Run flutter-skill:');
  print('     flutter-skill explore http://localhost:8080');
  print('     flutter-skill monkey http://localhost:8080');

  _printGuideFooter();
}

// ─── Shared Helpers ──────────────────────────────────────────────

Future<void> _runFullDemo(String url, {int? cdpPort}) async {
  final baseArgs = [url, '--headless'];
  if (cdpPort != null) baseArgs.add('--cdp-port=$cdpPort');

  // Create temp dir for diff baseline (cleaned up after)
  final diffBaselineDir = await Directory.systemTemp.createTemp('fs-baseline-');

  final steps = <String, Future<void> Function()>{
    '1/6  🔍 AI Explore — Discover UI, forms, accessibility issues': () =>
        runExplore([...baseArgs, '--depth=1']),
    '2/6  🐒 Monkey Test — Random fuzz testing to find crashes': () =>
        runMonkey([...baseArgs, '--actions=5']),
    '3/6  🔒 Security Scan — XSS, headers, cookies, HTTPS': () =>
        runSecurity([...baseArgs, '--depth=1', '--max-pages=3']),
    '4/6  📋 Test Plan — Generate test cases from UI analysis': () =>
        runPlan([...baseArgs, '--depth=1', '--max-pages=3']),
    '5/6  📸 Visual Diff — Screenshot baseline for regression testing': () =>
        runDiff([
          ...baseArgs,
          '--depth=1',
          '--max-pages=3',
          '--baseline=${diffBaselineDir.path}'
        ]),
    '6/6  🌐 Serve — Zero-config MCP server (tool discovery)': () =>
        _quickServeDemo(url, headless: true, cdpPort: cdpPort),
  };

  var passed = 0;
  var failed = 0;

  for (final entry in steps.entries) {
    print('');
    print('  ── ${entry.key} ──');
    print('');
    try {
      await entry.value();
      passed++;
    } catch (e) {
      print('  ⚠️  Failed: $e');
      failed++;
    }
  }

  // Cleanup diff baseline
  try {
    await diffBaselineDir.delete(recursive: true);
  } catch (_) {}

  print('');
  print('  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  print(
      '  📊 Quickstart Results: $passed/${passed + failed} commands succeeded');
  if (failed > 0) {
    print('     ($failed failed — check output above)');
  }
  print('  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
}

/// Quick serve demo: launch CDP, discover tools, print summary, close.
/// Does NOT start an HTTP server — just shows what serve would find.
Future<void> _quickServeDemo(String url,
    {bool headless = true, int? cdpPort}) async {
  print('🌐 flutter-skill serve — Zero-Config MCP Tool Discovery');
  print('');
  print('   URL: $url');
  print('');

  final cdp = CdpDriver(
    url: url,
    port: cdpPort ?? 0,
    launchChrome: (cdpPort ?? 0) == 0,
    headless: headless,
  );

  try {
    print('📡 Connecting via CDP...');
    await cdp.connect();
    await Future.delayed(const Duration(seconds: 2));
    print('✅ Connected');

    // Discover interactive elements (same logic as serve)
    final result = await cdp.evaluate('''
      (() => {
        const els = document.querySelectorAll(
          'a, button, input, select, textarea, [role="button"], [role="link"], [role="tab"], [onclick], [type="submit"]'
        );
        const tools = [];
        for (const el of els) {
          const tag = el.tagName.toLowerCase();
          const type = el.type || '';
          const text = (el.textContent || el.placeholder || el.name || el.id || '').trim().substring(0, 50);
          const role = el.getAttribute('role') || '';
          if (text || role) {
            tools.push({ tag, type, text, role });
          }
        }
        return JSON.stringify(tools);
      })()
    ''');

    final toolsJson = result['result']?['value'];
    if (toolsJson is String) {
      final tools = jsonDecode(toolsJson) as List;
      print('');
      print('🔍 Discovered ${tools.length} interactive elements:');
      for (final tool in tools.take(10)) {
        final t = tool as Map;
        final icon = t['tag'] == 'input'
            ? '📝'
            : t['tag'] == 'button'
                ? '🔘'
                : t['tag'] == 'a'
                    ? '🔗'
                    : t['tag'] == 'select'
                        ? '📋'
                        : '🎯';
        final label = t['text'] != '' ? t['text'] : t['role'];
        print(
            '   $icon ${t['tag']}${t['type'] != '' ? '[${t['type']}]' : ''}: $label');
      }
      if (tools.length > 10) {
        print('   ... and ${tools.length - 10} more');
      }
      print('');
      print('═══════════════════════════════════════════════');
      print('  🌐 Serve Discovery Complete');
      print('  Interactive elements: ${tools.length}');
      print('  Each element becomes an MCP tool that AI agents can call.');
      print('');
      print('  To start the full server:');
      print('    flutter-skill serve $url');
      print('═══════════════════════════════════════════════');
    }
  } finally {
    await cdp.disconnect();
  }
}

void _serveStatic(HttpServer server, String rootPath) {
  server.listen((request) async {
    final path = request.uri.path == '/' ? '/index.html' : request.uri.path;
    final file = File('$rootPath$path');
    if (await file.exists()) {
      final ext = path.split('.').last;
      final contentType = ext == 'html'
          ? 'text/html'
          : ext == 'js'
              ? 'application/javascript'
              : ext == 'css'
                  ? 'text/css'
                  : 'text/plain';
      request.response.headers.contentType = ContentType.parse(contentType);
      request.response.add(await file.readAsBytes());
    } else {
      request.response.statusCode = 404;
      request.response.write('Not found');
    }
    await request.response.close();
  });
}

Future<String?> _checkCommand(String command, List<String> args) async {
  try {
    final result = await Process.run(
      command,
      args,
      runInShell: Platform.isWindows,
    );
    if (result.exitCode == 0) {
      return result.stdout.toString();
    }
  } catch (_) {}
  return null;
}

Future<String?> _findFlutter() async {
  // On Windows try flutter.bat first (flutter is a bash script on Windows)
  if (Platform.isWindows) {
    final batInPath = await _checkCommand('flutter.bat', ['--version']);
    if (batInPath != null) return 'flutter.bat';
  }

  // Check PATH
  final inPath = await _checkCommand('flutter', ['--version']);
  if (inPath != null) return 'flutter';

  // Check common locations
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  final candidates = [
    if (home != null) ...[
      '$home/development/flutter/bin/flutter',
      '$home/flutter/bin/flutter',
      '$home/.flutter/bin/flutter',
      '$home/snap/flutter/common/flutter/bin/flutter',
      '$home/fvm/default/bin/flutter',
      // Windows-specific common paths
      if (Platform.isWindows) ...[
        r'C:\tools\flutter\bin\flutter.bat',
        r'C:\flutter\bin\flutter.bat',
        '${Platform.environment['LOCALAPPDATA']}\\flutter\\bin\\flutter.bat',
      ],
    ],
    '/opt/flutter/bin/flutter',
  ];
  for (final path in candidates) {
    if (await File(path).exists()) {
      final check = await _checkCommand(path, ['--version']);
      if (check != null) return path;
    }
  }
  return null;
}

Future<String?> _findChrome() async {
  if (Platform.isMacOS) {
    final path = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
    if (await File(path).exists()) return path;
  }
  // Try running it
  return await _checkCommand('google-chrome', ['--version']) ??
      await _checkCommand('chromium', ['--version']);
}

// ─── Summary Printers ────────────────────────────────────────────

void _printSummary(String url) {
  print('');
  print('═══════════════════════════════════════════════════════════');
  print('  🎉 Quickstart complete!');
  print('');
  print('  What just happened:');
  print('    1. 🔍 Explore — discovered UI elements, forms, a11y issues');
  print('    2. 🐒 Monkey — fuzz tested with random interactions');
  print('    3. 🔒 Security — scanned for XSS, header, cookie issues');
  print('    4. 📋 Plan — generated test cases from UI analysis');
  print('    5. 📸 Diff — created visual baseline for regression testing');
  print('    6. 🌐 Serve — discovered interactive elements as MCP tools');
  print('');
  print('  Next steps:');
  print('    flutter-skill serve $url        # full MCP server');
  print('    flutter-skill explore $url      # deeper exploration');
  print('    flutter-skill monkey $url       # longer fuzz test');
  print('    flutter-skill init              # setup your own project');
  print('');
  print('  Or ask your AI agent:');
  print('    "Test the login flow on $url"');
  print('    "Find accessibility issues"');
  print('    "Take a screenshot after clicking Login"');
  print('═══════════════════════════════════════════════════════════');
  print('');
}

void _printFlutterSummary(String url) {
  print('');
  print('═══════════════════════════════════════════════════════════');
  print('  🎉 Flutter quickstart complete!');
  print('');
  print('  What just happened:');
  print('    1. Created a temporary Flutter web app');
  print('    2. Ran 6 commands: explore, monkey, security, plan, diff, serve');
  print('    3. Generated reports: explore, security, diff, test plan');
  print('');
  print('  Next steps for YOUR Flutter app:');
  print('    1. flutter-skill init           # setup in your project');
  print('    2. flutter run -d chrome        # start your app');
  print('    3. flutter-skill explore <url>  # test it');
  print('');
  print('  Or add to your CI pipeline:');
  print('    flutter-skill monkey <url> --actions=100 --headless');
  print('═══════════════════════════════════════════════════════════');
  print('');
}

void _printElectronSummary(int cdpPort) {
  print('');
  print('═══════════════════════════════════════════════════════════');
  print('  🎉 Electron quickstart complete!');
  print('');
  print('  What just happened:');
  print('    1. Created a temporary Electron app');
  print('    2. Connected via CDP on port $cdpPort');
  print('    3. AI explored and monkey tested the app');
  print('');
  print('  For YOUR Electron app:');
  print('    1. Launch with: --remote-debugging-port=9222');
  print('    2. flutter-skill explore http://localhost:9222');
  print('    3. flutter-skill monkey http://localhost:9222');
  print('');
  print('  Add to package.json scripts:');
  print(
      '    "test:ai": "electron . --remote-debugging-port=9222 & flutter-skill explore http://localhost:9222"');
  print('═══════════════════════════════════════════════════════════');
  print('');
}

void _printSdkSummary(String url) {
  print('');
  print('═══════════════════════════════════════════════════════════');
  print('  🎉 Web SDK quickstart complete!');
  print('');
  print('  The SDK provides enhanced element discovery and interaction.');
  print('');
  print('  To add the SDK to your web app:');
  print('    <script src="https://cdn.flutterskill.dev/sdk.js"></script>');
  print('');
  print('  Next steps:');
  print('    flutter-skill init              # full project setup');
  print('    flutter-skill serve $url        # MCP server mode');
  print('═══════════════════════════════════════════════════════════');
  print('');
}

void _printGuideFooter() {
  print('');
  print('═══════════════════════════════════════════════════════════');
  print('  📖 More info: flutter-skill help');
  print('  🌐 Docs: https://flutterskill.dev/docs');
  print('');
  print('  Want to try the web demo instead?');
  print('    flutter-skill quickstart --platform=web');
  print('═══════════════════════════════════════════════════════════');
  print('');
}

// ─── Electron Main JS ────────────────────────────────────────────

String _electronMainJs(int serverPort) => '''
const { app, BrowserWindow } = require('electron');

app.whenReady().then(() => {
  const win = new BrowserWindow({
    width: 800,
    height: 600,
    webPreferences: { nodeIntegration: false, contextIsolation: true }
  });
  win.loadURL('http://localhost:$serverPort');
});

app.on('window-all-closed', () => app.quit());
''';

// ─── Flutter Demo Main ───────────────────────────────────────────

const _flutterDemoMain = r'''
import 'package:flutter/material.dart';

void main() {
  runApp(const DemoApp());
}

class DemoApp extends StatelessWidget {
  const DemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'flutter-skill Demo',
      theme: ThemeData(
        colorSchemeSeed: Colors.blue,
        useMaterial3: true,
      ),
      home: const LoginPage(),
    );
  }
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  void _login() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const TodoPage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Login')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextField(
              key: const Key('email'),
              controller: _emailController,
              decoration: const InputDecoration(
                labelText: 'Email',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('password'),
              controller: _passwordController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Password',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _login,
              child: const Text('Login'),
            ),
          ],
        ),
      ),
    );
  }
}

class TodoPage extends StatefulWidget {
  const TodoPage({super.key});
  @override
  State<TodoPage> createState() => _TodoPageState();
}

class _TodoPageState extends State<TodoPage> {
  final _todos = <String>[];
  final _controller = TextEditingController();

  void _addTodo() {
    if (_controller.text.isNotEmpty) {
      setState(() {
        _todos.add(_controller.text);
        _controller.clear();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Todos')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('todo-input'),
                    controller: _controller,
                    decoration: const InputDecoration(
                      hintText: 'Add a todo',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _addTodo,
                  child: const Text('Add'),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: _todos.length,
              itemBuilder: (_, i) => ListTile(
                title: Text(_todos[i]),
                trailing: IconButton(
                  icon: const Icon(Icons.delete),
                  onPressed: () => setState(() => _todos.removeAt(i)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
''';

// ─── Demo HTML ───────────────────────────────────────────────────

const _demoHtml = '''<!DOCTYPE html>
<html>
<head>
  <title>flutter-skill Demo App</title>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <style>
    body { font-family: -apple-system, sans-serif; max-width: 480px; margin: 40px auto; padding: 0 20px; }
    h1 { color: #1a73e8; }
    input, button { padding: 10px; margin: 5px 0; font-size: 16px; border-radius: 6px; border: 1px solid #ccc; }
    button { background: #1a73e8; color: white; border: none; cursor: pointer; }
    button:hover { background: #1557b0; }
    ul { list-style: none; padding: 0; }
    li { padding: 10px; margin: 4px 0; background: #f1f3f4; border-radius: 6px; cursor: pointer; }
    li:hover { background: #e8eaed; text-decoration: line-through; }
    form { display: flex; flex-direction: column; gap: 8px; }
  </style>
</head>
<body>
  <h1>Demo App</h1>
  <form id="login-form">
    <input type="email" placeholder="Email" id="email" required>
    <input type="password" placeholder="Password" id="password" required>
    <button type="submit">Login</button>
  </form>
  <div id="todo-section" style="display:none">
    <h2>Todos</h2>
    <div style="display:flex;gap:8px">
      <input id="todo-input" placeholder="Add todo" style="flex:1">
      <button onclick="addTodo()">Add</button>
    </div>
    <ul id="todo-list"></ul>
  </div>
  <!-- Intentional a11y issues for demo -->
  <img src="logo.png">
  <a href="#">Click here</a>
  <div onclick="alert('clicked')" style="width:20px;height:20px;background:blue"></div>
  <script>
    document.getElementById('login-form').onsubmit = function(e) {
      e.preventDefault();
      document.getElementById('login-form').style.display = 'none';
      document.getElementById('todo-section').style.display = 'block';
    };
    function addTodo() {
      var input = document.getElementById('todo-input');
      if (input.value) {
        var li = document.createElement('li');
        li.textContent = input.value;
        li.onclick = function() { this.remove(); };
        document.getElementById('todo-list').appendChild(li);
        input.value = '';
      }
    }
  </script>
</body>
</html>''';

const _demoHtmlWithSdk = '''<!DOCTYPE html>
<html>
<head>
  <title>flutter-skill SDK Demo</title>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <style>
    body { font-family: -apple-system, sans-serif; max-width: 480px; margin: 40px auto; padding: 0 20px; }
    h1 { color: #1a73e8; }
    input, button { padding: 10px; margin: 5px 0; font-size: 16px; border-radius: 6px; border: 1px solid #ccc; }
    button { background: #1a73e8; color: white; border: none; cursor: pointer; }
    button:hover { background: #1557b0; }
    ul { list-style: none; padding: 0; }
    li { padding: 10px; margin: 4px 0; background: #f1f3f4; border-radius: 6px; cursor: pointer; }
    li:hover { background: #e8eaed; text-decoration: line-through; }
    form { display: flex; flex-direction: column; gap: 8px; }
    .sdk-badge { position: fixed; bottom: 10px; right: 10px; background: #1a73e8; color: white; padding: 4px 8px; border-radius: 4px; font-size: 12px; opacity: 0.7; }
  </style>
  <!-- flutter-skill SDK -->
  <script src="https://cdn.flutterskill.dev/sdk.js"></script>
</head>
<body>
  <h1>SDK Demo App</h1>
  <form id="login-form">
    <input type="email" placeholder="Email" id="email" data-testid="email" required>
    <input type="password" placeholder="Password" id="password" data-testid="password" required>
    <button type="submit" data-testid="login-btn">Login</button>
  </form>
  <div id="todo-section" style="display:none">
    <h2>Todos</h2>
    <div style="display:flex;gap:8px">
      <input id="todo-input" data-testid="todo-input" placeholder="Add todo" style="flex:1">
      <button onclick="addTodo()" data-testid="add-btn">Add</button>
    </div>
    <ul id="todo-list" data-testid="todo-list"></ul>
  </div>
  <div class="sdk-badge">flutter-skill SDK</div>
  <script>
    document.getElementById('login-form').onsubmit = function(e) {
      e.preventDefault();
      document.getElementById('login-form').style.display = 'none';
      document.getElementById('todo-section').style.display = 'block';
    };
    function addTodo() {
      var input = document.getElementById('todo-input');
      if (input.value) {
        var li = document.createElement('li');
        li.textContent = input.value;
        li.onclick = function() { this.remove(); };
        document.getElementById('todo-list').appendChild(li);
        input.value = '';
      }
    }
  </script>
</body>
</html>''';
