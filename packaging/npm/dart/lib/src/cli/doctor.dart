import 'dart:io';
import 'dart:convert';
import 'package:flutter_skill/src/cli/server.dart' show currentVersion;

/// Run the doctor command to check installation health
Future<void> runDoctor(List<String> args) async {
  print('');
  print('🔍 flutter-skill doctor');
  print('');

  int okCount = 0;
  int warnCount = 0;
  int errorCount = 0;

  void ok(String msg) {
    print('    ✅ $msg');
    okCount++;
  }

  void warn(String msg, [String? fix]) {
    print('    ⚠️  $msg');
    if (fix != null) print('       → $fix');
    warnCount++;
  }

  void err(String msg, [String? fix]) {
    print('    ❌ $msg');
    if (fix != null) print('       → $fix');
    errorCount++;
  }

  // ── Environment ──
  print('  Environment:');

  // Flutter Skill version
  ok('flutter-skill v$currentVersion');

  // Dart SDK
  final dartVersion = await _run('dart', ['--version']);
  if (dartVersion != null) {
    ok('Dart SDK: ${dartVersion.trim()}');
  } else {
    err('Dart SDK not found', 'Install: https://dart.dev/get-dart');
  }

  // Chrome
  String? chromePath;
  if (Platform.isMacOS) {
    chromePath = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
    if (await File(chromePath).exists()) {
      final r = await Process.run(chromePath, ['--version']);
      ok('Chrome: ${(r.stdout as String).trim()}');
    } else {
      chromePath = null;
    }
  }
  if (chromePath == null) {
    final which = await _run('which', ['google-chrome']);
    if (which != null) {
      ok('Chrome found');
    } else {
      warn('Chrome not found', 'Needed for serve/explore/monkey commands');
    }
  }

  // CDP port
  if (await _isPortAvailable(9222)) {
    ok('CDP port 9222 available');
  } else {
    warn('Port 9222 in use', 'Use --cdp-port flag to specify another port');
  }

  // Bridge port
  if (await _isPortAvailable(18118)) {
    ok('Bridge port 18118 available');
  } else {
    ok('Bridge port 18118 active (app may be running)');
  }

  // Node.js
  final nodeVersion = await _run('node', ['--version']);
  if (nodeVersion != null) {
    ok('Node.js ${nodeVersion.trim()} (for Electron/RN)');
  } else {
    warn('Node.js not found', 'Needed for Electron & React Native projects');
  }

  // ── Mobile ──
  print('');
  print('  Mobile:');

  // Android SDK
  final androidHome = Platform.environment['ANDROID_HOME'] ??
      Platform.environment['ANDROID_SDK_ROOT'];
  if (androidHome != null && Directory(androidHome).existsSync()) {
    // Try to get API level
    final platformsDir = Directory('$androidHome/platforms');
    if (platformsDir.existsSync()) {
      final apis = platformsDir
          .listSync()
          .map((e) => e.path.split(Platform.pathSeparator).last)
          .where((n) => n.startsWith('android-'))
          .toList()
        ..sort();
      if (apis.isNotEmpty) {
        ok('Android SDK found (${apis.last})');
      } else {
        ok('Android SDK found');
      }
    } else {
      ok('Android SDK found');
    }
  } else {
    warn('Android SDK not found', 'Set ANDROID_HOME environment variable');
  }

  // ADB
  final adbDevices = await _run('adb', ['devices', '-l']);
  if (adbDevices != null) {
    final lines = adbDevices
        .split('\n')
        .skip(1)
        .where((l) => l.trim().isNotEmpty && l.contains('device'));
    if (lines.isNotEmpty) {
      for (final line in lines) {
        final parts = line.trim().split(RegExp(r'\s+'));
        final id = parts.first;
        final model = RegExp(r'model:(\S+)').firstMatch(line)?.group(1) ?? '';
        ok('ADB connected: $id${model.isNotEmpty ? " ($model)" : ""}');
      }
    } else {
      warn('No ADB devices connected');
    }
  } else {
    warn('adb not available', 'Install Android SDK Platform Tools');
  }

  // Xcode (macOS only)
  if (Platform.isMacOS) {
    final xcodeVersion = await _run('xcodebuild', ['-version']);
    if (xcodeVersion != null) {
      final firstLine = xcodeVersion.split('\n').first.trim();
      ok(firstLine);
    } else {
      warn('Xcode not found', 'Install from App Store');
    }

    // iOS Simulator
    try {
      final result = await Process.run(
        'xcrun',
        ['simctl', 'list', 'devices', 'booted', '-j'],
      );
      if (result.exitCode == 0) {
        final json = jsonDecode(result.stdout as String);
        final devices = json['devices'] as Map<String, dynamic>? ?? {};
        bool found = false;
        for (final runtime in devices.values) {
          if (runtime is List) {
            for (final device in runtime) {
              if (device['state'] == 'Booted') {
                ok('iOS Simulator: ${device['name']} (booted)');
                found = true;
              }
            }
          }
        }
        if (!found) {
          warn('No booted iOS Simulators');
        }
      }
    } catch (_) {
      warn('Could not check iOS Simulators');
    }
  }

  // ── Project ──
  print('');
  print('  Project:');

  final configFile = File('.flutter-skill.yaml');
  if (configFile.existsSync()) {
    ok('.flutter-skill.yaml found');
    // Parse project type
    final configContent = configFile.readAsStringSync();
    final typeMatch = RegExp(r'type:\s*(\S+)').firstMatch(configContent);
    if (typeMatch != null) {
      ok('Project type: ${typeMatch.group(1)}');
    }
  } else {
    warn('.flutter-skill.yaml not found', 'Run: flutter-skill init');
  }

  // Check pubspec for flutter_skill
  final pubspec = File('pubspec.yaml');
  if (pubspec.existsSync()) {
    final content = pubspec.readAsStringSync();
    final match = RegExp(r'flutter_skill:\s*\^?(\S+)').firstMatch(content);
    if (match != null) {
      ok('SDK installed: flutter_skill ^${match.group(1)}');
    } else {
      warn('flutter_skill not in pubspec.yaml', 'Run: flutter-skill init');
    }
  }

  // ── Network ──
  print('');
  print('  Network:');

  // Internet check
  try {
    final result =
        await Process.run('ping', ['-c', '1', '-W', '2', 'google.com']);
    if (result.exitCode == 0) {
      ok('Internet connection');
    } else {
      warn('No internet connection');
    }
  } catch (_) {
    warn('Could not check internet connection');
  }

  // Proxy
  final httpProxy = Platform.environment['HTTP_PROXY'] ??
      Platform.environment['http_proxy'] ??
      Platform.environment['HTTPS_PROXY'] ??
      Platform.environment['https_proxy'];
  if (httpProxy != null && httpProxy.isNotEmpty) {
    warn('Proxy detected: $httpProxy');
  } else {
    ok('No proxy detected');
  }

  // Port 3000
  if (await _isPortAvailable(3000)) {
    ok('Port 3000 available (serve command)');
  } else {
    warn('Port 3000 in use');
  }

  // ── Optional ──
  print('');
  print('  Optional:');

  // gh CLI
  if (await _commandExists('gh')) {
    ok('gh CLI available');
  } else {
    warn('gh CLI not found', 'Needed for create_github_issue tool');
  }

  // ffmpeg
  if (await _commandExists('ffmpeg')) {
    ok('ffmpeg available');
  } else {
    warn('ffmpeg not found', 'Needed for video recording');
  }

  // ── MCP Config ──
  print('');
  print('  AI Agent Config:');

  final homeDir =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  if (homeDir != null) {
    final claudeSettings = File('$homeDir/.claude/settings.json');
    if (claudeSettings.existsSync()) {
      try {
        final content = claudeSettings.readAsStringSync();
        if (content.contains('flutter-skill') ||
            content.contains('flutter_skill')) {
          ok('Claude Code MCP: configured');
        } else {
          warn('Claude Code MCP: not configured', 'Run: flutter-skill init');
        }
      } catch (_) {
        warn('Claude Code MCP: could not read settings');
      }
    } else {
      warn('Claude Code: not configured', 'Run: flutter-skill init');
    }

    final cursorConfig = File('$homeDir/.cursor/mcp.json');
    if (cursorConfig.existsSync()) {
      try {
        final content = cursorConfig.readAsStringSync();
        if (content.contains('flutter-skill') ||
            content.contains('flutter_skill')) {
          ok('Cursor MCP: configured');
        } else {
          warn('Cursor MCP: not configured');
        }
      } catch (_) {}
    }
  }

  // ── Summary ──
  print('');
  print('  ─────────────────────────────────────────────');
  if (errorCount == 0 && warnCount == 0) {
    print('  ✅ All checks passed! ($okCount OK)');
  } else if (errorCount == 0) {
    print('  $okCount OK, $warnCount warnings');
  } else {
    print('  $okCount OK, $warnCount warnings, $errorCount errors');
  }
  print('');
}

// ─── Helpers ─────────────────────────────────────────────────────

Future<String?> _run(String command, List<String> args) async {
  try {
    final result = await Process.run(command, args);
    if (result.exitCode == 0) {
      final out = (result.stdout as String).trim();
      if (out.isNotEmpty) return out;
      final errOut = (result.stderr as String).trim();
      if (errOut.isNotEmpty) return errOut;
    }
  } catch (_) {}
  return null;
}

Future<bool> _commandExists(String command) async {
  try {
    final result = await Process.run('which', [command]);
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}

Future<bool> _isPortAvailable(int port) async {
  try {
    final result = await Process.run('lsof', ['-i', ':$port', '-t']);
    return result.exitCode != 0 || (result.stdout as String).trim().isEmpty;
  } catch (_) {
    return true; // assume available if can't check
  }
}
