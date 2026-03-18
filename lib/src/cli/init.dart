import 'dart:io';
import 'dart:convert';

/// Detected project platform.
enum ProjectPlatform {
  flutter,
  reactNative,
  electron,
  tauri,
  maui,
  kmp,
  webSdk,
  webCdp,
  unknown,
}

/// Auto-detect project type and set up flutter-skill.
Future<void> runInit(List<String> args) async {
  final projectPath = args.isNotEmpty ? args[0] : '.';
  final dir = Directory(projectPath);

  if (!dir.existsSync()) {
    print('❌ Directory not found: $projectPath');
    exit(1);
  }

  final absPath = dir.absolute.path;
  print('');
  print('🔍 Detecting project type in: $absPath');
  print('');

  final platform = _detectPlatform(absPath);
  final projectName = _getProjectName(absPath, platform);

  print('✅ Detected: ${_platformLabel(platform)}');
  print('');

  // Setup SDK
  await _setupSdk(platform, absPath);

  // Generate config
  _generateConfig(absPath, platform, projectName);

  // Auto-configure MCP for AI agents
  await _configureMCP();

  // Print next steps
  _printNextSteps(platform, projectName);
}

// ─── Detection ───────────────────────────────────────────────────

ProjectPlatform _detectPlatform(String path) {
  // 1. Flutter
  final pubspec = File('$path/pubspec.yaml');
  if (pubspec.existsSync()) {
    return ProjectPlatform.flutter;
  }

  // 2-3. package.json checks
  final packageJson = File('$path/package.json');
  if (packageJson.existsSync()) {
    try {
      final content = jsonDecode(packageJson.readAsStringSync()) as Map;
      final deps = <String, dynamic>{
        ...(content['dependencies'] as Map? ?? {}),
        ...(content['devDependencies'] as Map? ?? {}),
      };

      // 2. React Native
      if (deps.containsKey('react-native')) {
        return ProjectPlatform.reactNative;
      }

      // 3. Electron
      if (deps.containsKey('electron')) {
        return ProjectPlatform.electron;
      }
    } catch (_) {}
  }

  // 4. Tauri
  final cargoToml = File('$path/Cargo.toml');
  if (cargoToml.existsSync()) {
    final content = cargoToml.readAsStringSync();
    if (content.contains('tauri')) {
      return ProjectPlatform.tauri;
    }
  }
  // Also check src-tauri
  final tauriDir = Directory('$path/src-tauri');
  if (tauriDir.existsSync()) {
    return ProjectPlatform.tauri;
  }

  // 5. .NET MAUI
  try {
    final csprojFiles = Directory(path)
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.csproj'));
    for (final f in csprojFiles) {
      final content = f.readAsStringSync();
      if (content.contains('Microsoft.Maui') || content.contains('Maui')) {
        return ProjectPlatform.maui;
      }
    }
  } catch (_) {}

  // 6. KMP
  final buildGradleKts = File('$path/build.gradle.kts');
  if (buildGradleKts.existsSync()) {
    final content = buildGradleKts.readAsStringSync();
    if (content.contains('compose') || content.contains('kotlin')) {
      return ProjectPlatform.kmp;
    }
  }

  // 7. Web frameworks via package.json
  if (packageJson.existsSync()) {
    try {
      final content = jsonDecode(packageJson.readAsStringSync()) as Map;
      final deps = <String, dynamic>{
        ...(content['dependencies'] as Map? ?? {}),
        ...(content['devDependencies'] as Map? ?? {}),
      };
      const webFrameworks = [
        'react',
        'vue',
        'angular',
        '@angular/core',
        'svelte',
        'next',
        'nuxt',
        '@sveltejs/kit',
      ];
      for (final fw in webFrameworks) {
        if (deps.containsKey(fw)) {
          return ProjectPlatform.webSdk;
        }
      }
    } catch (_) {}
  }

  // 8. index.html
  for (final p in [
    '$path/index.html',
    '$path/public/index.html',
    '$path/web/index.html'
  ]) {
    if (File(p).existsSync()) {
      return ProjectPlatform.webSdk;
    }
  }

  // 9. Default: Web CDP (zero SDK)
  return ProjectPlatform.webCdp;
}

String _getProjectName(String path, ProjectPlatform platform) {
  // Try pubspec.yaml
  final pubspec = File('$path/pubspec.yaml');
  if (pubspec.existsSync()) {
    final match = RegExp(r'^name:\s*(\S+)', multiLine: true)
        .firstMatch(pubspec.readAsStringSync());
    if (match != null) return match.group(1)!;
  }

  // Try package.json
  final packageJson = File('$path/package.json');
  if (packageJson.existsSync()) {
    try {
      final content = jsonDecode(packageJson.readAsStringSync()) as Map;
      if (content['name'] is String) return content['name'] as String;
    } catch (_) {}
  }

  // Fallback to directory name
  return path.split(Platform.pathSeparator).last;
}

String _platformLabel(ProjectPlatform platform) {
  switch (platform) {
    case ProjectPlatform.flutter:
      return '🐦 Flutter (Dart)';
    case ProjectPlatform.reactNative:
      return '⚛️  React Native';
    case ProjectPlatform.electron:
      return '⚡ Electron';
    case ProjectPlatform.tauri:
      return '🦀 Tauri';
    case ProjectPlatform.maui:
      return '🟣 .NET MAUI';
    case ProjectPlatform.kmp:
      return '🟠 Kotlin Multiplatform';
    case ProjectPlatform.webSdk:
      return '🌐 Web (with SDK)';
    case ProjectPlatform.webCdp:
      return '🌐 Web (CDP — zero SDK)';
    case ProjectPlatform.unknown:
      return '❓ Unknown';
  }
}

String _platformTypeString(ProjectPlatform platform) {
  switch (platform) {
    case ProjectPlatform.flutter:
      return 'flutter';
    case ProjectPlatform.reactNative:
      return 'react-native';
    case ProjectPlatform.electron:
      return 'electron';
    case ProjectPlatform.tauri:
      return 'tauri';
    case ProjectPlatform.maui:
      return 'maui';
    case ProjectPlatform.kmp:
      return 'kmp';
    case ProjectPlatform.webSdk:
      return 'web';
    case ProjectPlatform.webCdp:
      return 'web-cdp';
    case ProjectPlatform.unknown:
      return 'unknown';
  }
}

// ─── SDK Setup ───────────────────────────────────────────────────

Future<void> _setupSdk(ProjectPlatform platform, String path) async {
  switch (platform) {
    case ProjectPlatform.flutter:
      await _setupFlutter(path);
      break;
    case ProjectPlatform.reactNative:
      await _setupReactNative(path);
      break;
    case ProjectPlatform.electron:
      await _setupElectron(path);
      break;
    case ProjectPlatform.tauri:
      _setupTauri(path);
      break;
    case ProjectPlatform.maui:
      _setupMaui();
      break;
    case ProjectPlatform.kmp:
      _setupKmp();
      break;
    case ProjectPlatform.webSdk:
      await _setupWeb(path);
      break;
    case ProjectPlatform.webCdp:
      _setupWebCdp();
      break;
    case ProjectPlatform.unknown:
      _setupWebCdp();
      break;
  }
}

Future<void> _setupFlutter(String path) async {
  print('📦 Setting up Flutter SDK...');

  final pubspec = File('$path/pubspec.yaml');
  final content = pubspec.readAsStringSync();

  if (!content.contains('flutter_skill:')) {
    // Add to dev_dependencies
    if (content.contains('dev_dependencies:')) {
      final updated = content.replaceFirst(
        'dev_dependencies:',
        'dev_dependencies:\n  flutter_skill: ^0.8.6',
      );
      pubspec.writeAsStringSync(updated);
      print('   ✅ Added flutter_skill to dev_dependencies');
    } else {
      pubspec.writeAsStringSync(
          '$content\ndev_dependencies:\n  flutter_skill: ^0.8.6\n');
      print('   ✅ Added flutter_skill to dev_dependencies');
    }
  } else {
    print('   ✅ flutter_skill already in pubspec.yaml');
  }

  // Create snippet
  print('');
  print('   📝 Add to your main.dart:');
  print("      import 'package:flutter_skill/flutter_skill.dart';");
  print("      import 'package:flutter/foundation.dart';");
  print('      // In main():');
  print('      if (kDebugMode) { FlutterSkillBinding.ensureInitialized(); }');
}

Future<void> _setupReactNative(String path) async {
  print('📦 Setting up React Native SDK...');

  final sdkFile = File('$path/FlutterSkill.js');
  if (!sdkFile.existsSync()) {
    sdkFile.writeAsStringSync(_reactNativeSdkContent);
    print('   ✅ Created FlutterSkill.js');
  } else {
    print('   ✅ FlutterSkill.js already exists');
  }
}

Future<void> _setupElectron(String path) async {
  print('📦 Setting up Electron SDK...');

  final sdkFile = File('$path/flutter-skill-electron.js');
  if (!sdkFile.existsSync()) {
    sdkFile.writeAsStringSync(_electronSdkContent);
    print('   ✅ Created flutter-skill-electron.js');
  } else {
    print('   ✅ flutter-skill-electron.js already exists');
  }
}

void _setupTauri(String path) {
  print('📦 Tauri project detected.');
  print('');
  print('   Add to your Cargo.toml:');
  print('   [dependencies]');
  print('   flutter-skill = "0.1"');
  print('');
  print('   Or use Web CDP mode (no SDK needed):');
  print('   flutter-skill serve http://localhost:1420');
}

void _setupMaui() {
  print('📦 .NET MAUI project detected.');
  print('');
  print('   Use Web CDP mode (no SDK needed):');
  print('   flutter-skill serve <your-app-url>');
}

void _setupKmp() {
  print('📦 Kotlin Multiplatform project detected.');
  print('');
  print('   Use Web CDP mode for Compose Web targets:');
  print('   flutter-skill serve <your-app-url>');
}

Future<void> _setupWeb(String path) async {
  print('📦 Setting up Web SDK...');

  final sdkFile = File('$path/flutter-skill-web.js');
  if (!sdkFile.existsSync()) {
    sdkFile.writeAsStringSync(_webSdkContent);
    print('   ✅ Created flutter-skill-web.js');
  } else {
    print('   ✅ flutter-skill-web.js already exists');
  }

  print('');
  print('   Add before </body> in your HTML:');
  print('   <script src="flutter-skill-web.js"></script>');
}

void _setupWebCdp() {
  print('🎯 No SDK needed — zero-config CDP mode!');
  print('');
  print('   Just run:');
  print('   flutter-skill serve <your-app-url>');
}

// ─── Config Generation ───────────────────────────────────────────

void _generateConfig(String path, ProjectPlatform platform, String name) {
  final configFile = File('$path/.flutter-skill.yaml');
  if (configFile.existsSync()) {
    print('');
    print('   ℹ️  .flutter-skill.yaml already exists — skipping');
    return;
  }

  final defaultPlatform =
      (platform == ProjectPlatform.webCdp || platform == ProjectPlatform.webSdk)
          ? 'cdp'
          : 'bridge';

  final yaml = '''# Auto-generated by flutter-skill init
project:
  type: ${_platformTypeString(platform)}  # auto-detected
  name: $name

testing:
  default_platform: $defaultPlatform
  screenshot_format: jpeg
  screenshot_quality: 80

explore:
  depth: 3
  headless: true

monkey:
  max_actions: 100
  seed: null  # random
''';

  configFile.writeAsStringSync(yaml);
  print('');
  print('   ✅ Generated .flutter-skill.yaml');
}

// ─── Next Steps ──────────────────────────────────────────────────

void _printNextSteps(ProjectPlatform platform, String projectName) {
  print('');
  print('═══════════════════════════════════════════════════════════');
  print(
      '  ✅ flutter-skill initialized for ${_platformLabel(platform)} project!');
  print('');

  switch (platform) {
    case ProjectPlatform.flutter:
      print('  Next steps:');
      print("    1. Run: flutter pub get");
      print('    2. Add FlutterSkillBinding to main.dart (see above)');
      print('    3. Run your app: flutter run');
      print('    4. Test with AI: Ask Claude "test the login flow"');
      break;
    case ProjectPlatform.reactNative:
      print('  Next steps:');
      print("    1. Add to your App.js:  import './FlutterSkill';");
      print('    2. Run your app:         npx react-native run-ios');
      print('    3. Test with AI:         Ask Claude: "test the login flow"');
      break;
    case ProjectPlatform.electron:
      print('  Next steps:');
      print(
          "    1. Add to your main.js:  require('./flutter-skill-electron');");
      print('    2. Run your app:          npm start');
      print('    3. Test with AI:          Ask Claude: "test the app"');
      break;
    case ProjectPlatform.webSdk:
      print('  Next steps:');
      print('    1. Add <script src="flutter-skill-web.js"></script> to HTML');
      print('    2. Run your dev server');
      print('    3. Test with AI: Ask Claude: "test the login flow"');
      break;
    case ProjectPlatform.webCdp:
      print('  Next steps:');
      print('    1. Start your app / have a URL ready');
      print('    2. Run: flutter-skill serve <url>');
      print('    3. Test with AI: Ask Claude: "test the login flow"');
      break;
    default:
      print('  Next steps:');
      print('    1. Run: flutter-skill serve <your-app-url>');
      print('    2. Test with AI: Ask Claude: "test the app"');
      break;
  }

  print('');
  print('  Or try these commands:');
  print('    flutter-skill serve <url>     # zero-config web testing');
  print('    flutter-skill explore <url>   # AI autonomous testing');
  print('    flutter-skill monkey <url>    # fuzz testing');
  print('    flutter-skill quickstart      # guided demo');
  print('');
  print('  📖 Docs: https://github.com/ai-dashboad/flutter-skill');
  print('═══════════════════════════════════════════════════════════');
  print('');
}

// ─── MCP Auto-Config ─────────────────────────────────────────────

Future<void> _configureMCP() async {
  print('');
  print('🤖 Configuring AI agent MCP...');

  final home = Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'];
  if (home == null) {
    print('   Warning: Could not determine home directory');
    return;
  }

  // Claude Code
  final claudeSettings = File('$home/.claude/settings.json');
  if (await _addMCPConfig(claudeSettings, 'Claude Code')) return;

  // Cursor
  final cursorMCP = File('$home/.cursor/mcp.json');
  if (await _addMCPConfig(cursorMCP, 'Cursor')) return;

  // Create Claude Code config if nothing found
  print('   Creating Claude Code MCP config...');
  final claudeDir = Directory('$home/.claude');
  if (!claudeDir.existsSync()) claudeDir.createSync(recursive: true);

  final config = {
    'mcpServers': {
      'flutter-skill': {
        'command': 'flutter-skill',
        'args': ['server'],
      }
    }
  };

  if (claudeSettings.existsSync()) {
    try {
      final existing = jsonDecode(claudeSettings.readAsStringSync()) as Map;
      final servers = (existing['mcpServers'] as Map?) ?? {};
      if (!servers.containsKey('flutter-skill')) {
        servers['flutter-skill'] = config['mcpServers']!['flutter-skill'];
        existing['mcpServers'] = servers;
        claudeSettings.writeAsStringSync(
            const JsonEncoder.withIndent('  ').convert(existing));
        print('   ✅ Claude Code MCP configured');
      } else {
        print('   ✅ Claude Code MCP already configured');
      }
    } catch (_) {
      print('   ⚠️  Could not parse existing settings');
    }
  } else {
    claudeSettings
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(config));
    print('   ✅ Claude Code MCP configured');
  }
}

Future<bool> _addMCPConfig(File configFile, String agentName) async {
  if (!configFile.existsSync()) return false;

  try {
    final content = jsonDecode(configFile.readAsStringSync()) as Map;
    final servers = (content['mcpServers'] as Map?) ?? {};
    if (servers.containsKey('flutter-skill')) {
      print('   ✅ $agentName MCP already configured');
      return true;
    }
    servers['flutter-skill'] = {
      'command': 'flutter-skill',
      'args': ['server'],
    };
    content['mcpServers'] = servers;
    configFile
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(content));
    print('   ✅ $agentName MCP configured');
    return true;
  } catch (_) {
    return false;
  }
}

// ─── SDK Content Templates ───────────────────────────────────────

const _reactNativeSdkContent = '''
// FlutterSkill SDK for React Native
// Auto-generated by flutter-skill init

const FlutterSkill = {
  _ws: null,
  _port: 18118,

  start(options = {}) {
    if (__DEV__) {
      this._port = options.port || 18118;
      this._connect();
      console.log('[FlutterSkill] Bridge started on port ' + this._port);
    }
  },

  _connect() {
    try {
      this._ws = new WebSocket('ws://localhost:' + this._port);
      this._ws.onmessage = (event) => this._handleMessage(JSON.parse(event.data));
      this._ws.onclose = () => setTimeout(() => this._connect(), 3000);
    } catch (e) {
      setTimeout(() => this._connect(), 3000);
    }
  },

  _handleMessage(msg) {
    // Handle bridge commands
  }
};

export default FlutterSkill;
''';

const _electronSdkContent = '''
// FlutterSkill SDK for Electron
// Auto-generated by flutter-skill init

const { ipcMain, BrowserWindow } = require('electron');
const WebSocket = require('ws');

class FlutterSkillElectron {
  constructor(options = {}) {
    this.port = options.port || 18118;
    if (process.env.NODE_ENV === 'development') {
      this.start();
    }
  }

  start() {
    const wss = new WebSocket.Server({ port: this.port });
    wss.on('connection', (ws) => {
      ws.on('message', (data) => this.handleMessage(JSON.parse(data), ws));
    });
    console.log('[FlutterSkill] Electron bridge on port ' + this.port);
  }

  handleMessage(msg, ws) {
    // Handle bridge commands
  }
}

module.exports = FlutterSkillElectron;
''';

const _webSdkContent = '''
// FlutterSkill SDK for Web
// Auto-generated by flutter-skill init

(function() {
  if (location.hostname !== 'localhost' && location.hostname !== '127.0.0.1') return;

  const FlutterSkill = {
    _ws: null,
    _port: 18118,

    start(options) {
      options = options || {};
      this._port = options.port || 18118;
      this._connect();
    },

    _connect() {
      try {
        this._ws = new WebSocket('ws://localhost:' + this._port);
        this._ws.onmessage = function(event) {
          FlutterSkill._handleMessage(JSON.parse(event.data));
        };
        this._ws.onclose = function() {
          setTimeout(function() { FlutterSkill._connect(); }, 3000);
        };
      } catch (e) {
        setTimeout(function() { FlutterSkill._connect(); }, 3000);
      }
    },

    _handleMessage(msg) {
      // Handle bridge commands
    }
  };

  window.FlutterSkill = FlutterSkill;
  FlutterSkill.start();
})();
''';
