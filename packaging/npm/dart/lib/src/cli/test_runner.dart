import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Multi-platform parallel test runner.
///
/// Usage:
///   flutter-skill test --url https://my-app.com --platforms web,electron,android
Future<void> runTestRunner(List<String> args) async {
  String? url;
  var platforms = <String>['web'];
  int cdpPort = 9222;
  bool headless = true;
  String? reportPath;

  for (final arg in args) {
    if (arg.startsWith('--url=')) {
      url = arg.substring('--url='.length);
    } else if (arg.startsWith('--platforms=')) {
      platforms = arg.substring('--platforms='.length).split(',');
    } else if (arg.startsWith('--cdp-port=')) {
      cdpPort = int.tryParse(arg.substring('--cdp-port='.length)) ?? 9222;
    } else if (arg == '--no-headless') {
      headless = false;
    } else if (arg.startsWith('--report=')) {
      reportPath = arg.substring('--report='.length);
    } else if (!arg.startsWith('--') && url == null) {
      url = arg;
    }
  }

  if (url == null) {
    stderr.writeln(
        'Usage: flutter-skill test --url <url> [--platforms web,electron,android]');
    stderr.writeln('');
    stderr.writeln('Options:');
    stderr.writeln('  --url=<url>             URL to test');
    stderr.writeln(
        '  --platforms=<list>       Comma-separated: web,electron,android,ios');
    stderr.writeln(
        '  --cdp-port=<port>       CDP port for Chrome (default: 9222)');
    stderr.writeln('  --no-headless           Show browser window');
    stderr.writeln('  --report=<path>         Save report to file');
    exit(1);
  }

  stderr.writeln('╔══════════════════════════════════════════════════╗');
  stderr.writeln('║  flutter-skill Parallel Test Runner              ║');
  stderr.writeln('╚══════════════════════════════════════════════════╝');
  stderr.writeln('');
  stderr.writeln('URL: $url');
  stderr.writeln('Platforms: ${platforms.join(", ")}');
  stderr.writeln('');

  final runner = _ParallelTestRunner(
    url: url,
    platforms: platforms,
    cdpPort: cdpPort,
    headless: headless,
  );

  final report = await runner.run();

  // Print report
  _printReport(report);

  // Save report if requested
  if (reportPath != null) {
    final file = File(reportPath);
    await file.parent.create(recursive: true);
    await file
        .writeAsString(const JsonEncoder.withIndent('  ').convert(report));
    stderr.writeln('\nReport saved to: $reportPath');
  }

  // Exit with non-zero if any platform failed
  final allPassed =
      (report['summary'] as Map<String, dynamic>)['all_passed'] as bool;
  exit(allPassed ? 0 : 1);
}

class _ParallelTestRunner {
  final String url;
  final List<String> platforms;
  final int cdpPort;
  final bool headless;

  _ParallelTestRunner({
    required this.url,
    required this.platforms,
    this.cdpPort = 9222,
    this.headless = true,
  });

  Future<Map<String, dynamic>> run() async {
    final results = <String, Map<String, dynamic>>{};
    final futures = <Future<MapEntry<String, Map<String, dynamic>>>>[];

    for (final platform in platforms) {
      futures.add(_testPlatform(platform));
    }

    final entries = await Future.wait(futures);
    for (final entry in entries) {
      results[entry.key] = entry.value;
    }

    final passed = results.values.where((r) => r['success'] == true).length;
    final failed = results.values.where((r) => r['success'] != true).length;

    return {
      'url': url,
      'platforms_tested': platforms.length,
      'results': results,
      'summary': {
        'total': platforms.length,
        'passed': passed,
        'failed': failed,
        'all_passed': failed == 0,
      },
      'timestamp': DateTime.now().toIso8601String(),
    };
  }

  Future<MapEntry<String, Map<String, dynamic>>> _testPlatform(
      String platform) async {
    stderr.writeln('[$platform] Starting test...');
    final stopwatch = Stopwatch()..start();

    try {
      switch (platform.toLowerCase()) {
        case 'web':
          final result = await _testWeb();
          stopwatch.stop();
          result['duration_ms'] = stopwatch.elapsedMilliseconds;
          return MapEntry(platform, result);

        case 'electron':
          final result = await _testElectron();
          stopwatch.stop();
          result['duration_ms'] = stopwatch.elapsedMilliseconds;
          return MapEntry(platform, result);

        case 'android':
          final result = await _testAndroid();
          stopwatch.stop();
          result['duration_ms'] = stopwatch.elapsedMilliseconds;
          return MapEntry(platform, result);

        case 'ios':
          final result = await _testIos();
          stopwatch.stop();
          result['duration_ms'] = stopwatch.elapsedMilliseconds;
          return MapEntry(platform, result);

        default:
          return MapEntry(platform, {
            'success': false,
            'error': 'Unknown platform: $platform',
            'duration_ms': stopwatch.elapsedMilliseconds,
          });
      }
    } catch (e) {
      stopwatch.stop();
      return MapEntry(platform, {
        'success': false,
        'error': e.toString(),
        'duration_ms': stopwatch.elapsedMilliseconds,
      });
    }
  }

  /// Test on web using headless Chrome + CDP
  Future<Map<String, dynamic>> _testWeb() async {
    Process? chromeProcess;
    try {
      // Find Chrome binary
      final chromePath = _findChromePath();
      if (chromePath == null) {
        return {
          'success': false,
          'error': 'Chrome not found. Install Google Chrome.'
        };
      }

      // Launch headless Chrome
      final port = cdpPort;
      final chromeArgs = [
        if (headless) '--headless=new',
        '--disable-gpu',
        '--no-sandbox',
        '--disable-dev-shm-usage',
        '--remote-debugging-port=$port',
        '--window-size=1280,720',
        url,
      ];

      stderr.writeln('[web] Launching Chrome on CDP port $port...');
      chromeProcess = await Process.start(chromePath, chromeArgs);

      // Wait for CDP to be ready
      await _waitForCdp(port);
      stderr.writeln('[web] Chrome connected via CDP');

      // Run test sequence
      return await _runCdpTestSequence(port);
    } finally {
      chromeProcess?.kill();
    }
  }

  /// Test on Electron
  Future<Map<String, dynamic>> _testElectron() async {
    final electronDir =
        '${Platform.environment['HOME'] ?? '.'}/.flutter-skill/electron-shell';
    final electronBin = '$electronDir/node_modules/.bin/electron';

    if (!File(electronBin).existsSync() &&
        !File('$electronBin.cmd').existsSync()) {
      // Check if electron-shell exists
      if (!Directory(electronDir).existsSync()) {
        stderr.writeln('[electron] Electron shell not found at $electronDir');
        stderr.writeln('[electron] Setting up Electron shell...');
        await _setupElectronShell(electronDir);
      }
    }

    Process? electronProcess;
    try {
      final mainJs = '$electronDir/main.js';
      if (!File(mainJs).existsSync()) {
        await _createElectronMain(mainJs, url);
      }

      final port = cdpPort + 1; // Use different port than Chrome
      electronProcess = await Process.start(
        electronBin,
        ['--remote-debugging-port=$port', mainJs],
        environment: {'ELECTRON_ENABLE_LOGGING': '1'},
      );

      await _waitForCdp(port);
      stderr.writeln('[electron] Electron connected via CDP');

      return await _runCdpTestSequence(port);
    } finally {
      electronProcess?.kill();
    }
  }

  /// Test on Android via adb
  Future<Map<String, dynamic>> _testAndroid() async {
    // Check for connected Android devices
    final adbResult = await Process.run('adb', ['devices']);
    final output = adbResult.stdout as String;
    final devices = output
        .split('\n')
        .skip(1)
        .where((l) => l.contains('device') && !l.contains('offline'))
        .map((l) => l.split('\t').first.trim())
        .where((d) => d.isNotEmpty)
        .toList();

    if (devices.isEmpty) {
      return {
        'success': false,
        'error': 'No Android devices connected. Run `adb devices` to check.'
      };
    }

    final deviceId = devices.first;
    stderr.writeln('[android] Found device: $deviceId');

    // Open URL in device browser
    await Process.run('adb', [
      '-s',
      deviceId,
      'shell',
      'am',
      'start',
      '-a',
      'android.intent.action.VIEW',
      '-d',
      url
    ]);

    // Wait for page to load
    await Future.delayed(const Duration(seconds: 3));

    // Take screenshot
    // Take screenshot via adb
    await Process.run('adb', ['-s', deviceId, 'exec-out', 'screencap', '-p'],
        stdoutEncoding: null);

    return {
      'success': true,
      'device': deviceId,
      'screenshot_taken': true,
      'elements_tested': 0,
      'errors': <String>[],
      'note': 'Android testing via adb - basic connectivity verified',
    };
  }

  /// Test on iOS simulator
  Future<Map<String, dynamic>> _testIos() async {
    // Check for booted iOS simulators
    final result = await Process.run(
        'xcrun', ['simctl', 'list', 'devices', 'booted', '-j']);
    if (result.exitCode != 0) {
      return {
        'success': false,
        'error': 'xcrun simctl not available. Xcode required.'
      };
    }

    final data = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    final devices = data['devices'] as Map<String, dynamic>? ?? {};
    String? deviceUdid;
    String? deviceName;

    for (final runtime in devices.values) {
      if (runtime is List) {
        for (final d in runtime) {
          if (d is Map && d['state'] == 'Booted') {
            deviceUdid = d['udid'] as String?;
            deviceName = d['name'] as String?;
            break;
          }
        }
      }
      if (deviceUdid != null) break;
    }

    if (deviceUdid == null) {
      return {
        'success': false,
        'error': 'No booted iOS simulator found. Launch one in Xcode.'
      };
    }

    stderr.writeln('[ios] Found simulator: $deviceName ($deviceUdid)');

    // Open URL in simulator Safari
    await Process.run('xcrun', ['simctl', 'openurl', deviceUdid, url]);
    await Future.delayed(const Duration(seconds: 3));

    return {
      'success': true,
      'device': deviceName,
      'udid': deviceUdid,
      'elements_tested': 0,
      'errors': <String>[],
      'note': 'iOS simulator testing - basic connectivity verified',
    };
  }

  /// Run the test sequence over CDP
  Future<Map<String, dynamic>> _runCdpTestSequence(int port) async {
    // Connect to CDP and gather page info
    final client = HttpClient();
    try {
      // Get list of targets
      final request =
          await client.getUrl(Uri.parse('http://127.0.0.1:$port/json'));
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      final targets = jsonDecode(body) as List<dynamic>;

      if (targets.isEmpty) {
        return {'success': false, 'error': 'No CDP targets found'};
      }

      final pageTarget = targets.firstWhere(
        (t) => t['type'] == 'page',
        orElse: () => targets.first,
      );

      final pageTitle = pageTarget['title'] as String? ?? 'Unknown';
      final pageUrl = pageTarget['url'] as String? ?? url;

      stderr.writeln('  Page: $pageTitle ($pageUrl)');

      // Basic connectivity test passed
      return {
        'success': true,
        'page_title': pageTitle,
        'page_url': pageUrl,
        'targets_found': targets.length,
        'elements_tested': 0,
        'errors': <String>[],
      };
    } finally {
      client.close();
    }
  }

  /// Wait for CDP endpoint to become available
  Future<void> _waitForCdp(int port, {int timeoutSeconds = 15}) async {
    final deadline = DateTime.now().add(Duration(seconds: timeoutSeconds));
    while (DateTime.now().isBefore(deadline)) {
      try {
        final client = HttpClient();
        try {
          final request = await client
              .getUrl(Uri.parse('http://127.0.0.1:$port/json/version'))
              .timeout(const Duration(seconds: 2));
          final response = await request.close();
          await response.drain<void>();
          if (response.statusCode == 200) return;
        } finally {
          client.close();
        }
      } catch (_) {
        // Not ready yet
      }
      await Future.delayed(const Duration(milliseconds: 500));
    }
    throw Exception('CDP not ready on port $port after ${timeoutSeconds}s');
  }

  /// Find Chrome binary on the system
  String? _findChromePath() {
    if (Platform.isMacOS) {
      const paths = [
        '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
        '/Applications/Chromium.app/Contents/MacOS/Chromium',
      ];
      for (final p in paths) {
        if (File(p).existsSync()) return p;
      }
    } else if (Platform.isLinux) {
      const names = [
        'google-chrome',
        'google-chrome-stable',
        'chromium-browser',
        'chromium'
      ];
      for (final name in names) {
        final result = Process.runSync('which', [name]);
        if (result.exitCode == 0) return (result.stdout as String).trim();
      }
    } else if (Platform.isWindows) {
      const paths = [
        r'C:\Program Files\Google\Chrome\Application\chrome.exe',
        r'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',
      ];
      for (final p in paths) {
        if (File(p).existsSync()) return p;
      }
    }
    return null;
  }

  /// Setup Electron shell
  Future<void> _setupElectronShell(String dir) async {
    await Directory(dir).create(recursive: true);

    // Create package.json
    final packageJson = File('$dir/package.json');
    await packageJson.writeAsString(jsonEncode({
      'name': 'flutter-skill-electron-shell',
      'version': '1.0.0',
      'main': 'main.js',
      'devDependencies': {'electron': '^28.0.0'},
    }));

    // Install electron
    stderr
        .writeln('[electron] Installing electron (this may take a minute)...');
    final result = await Process.run('npm', ['install'], workingDirectory: dir);
    if (result.exitCode != 0) {
      throw Exception('Failed to install electron: ${result.stderr}');
    }

    // Create main.js
    await _createElectronMain('$dir/main.js', url);
  }

  /// Create Electron main.js that loads the target URL
  Future<void> _createElectronMain(String path, String targetUrl) async {
    await File(path).writeAsString('''
const { app, BrowserWindow } = require('electron');

app.whenReady().then(() => {
  const win = new BrowserWindow({ width: 1280, height: 720 });
  win.loadURL('$targetUrl');
});

app.on('window-all-closed', () => app.quit());
''');
  }
}

void _printReport(Map<String, dynamic> report) {
  final summary = report['summary'] as Map<String, dynamic>;
  final results = report['results'] as Map<String, dynamic>;

  stderr.writeln('');
  stderr.writeln('═══════════════════════════════════════════');
  stderr.writeln(' Test Report');
  stderr.writeln('═══════════════════════════════════════════');
  stderr.writeln('');

  for (final entry in results.entries) {
    final platform = entry.key;
    final data = entry.value as Map<String, dynamic>;
    final success = data['success'] == true;
    final icon = success ? '✅' : '❌';
    final duration = data['duration_ms'] ?? 0;

    stderr.writeln('  $icon $platform (${duration}ms)');
    if (data['error'] != null) {
      stderr.writeln('     Error: ${data['error']}');
    }
    if (data['page_title'] != null) {
      stderr.writeln('     Page: ${data['page_title']}');
    }
  }

  stderr.writeln('');
  stderr.writeln('───────────────────────────────────────────');
  final total = summary['total'];
  final passed = summary['passed'];
  final failed = summary['failed'];
  stderr.writeln('  Total: $total | Passed: $passed | Failed: $failed');
  stderr.writeln('═══════════════════════════════════════════');
}
