import 'dart:io';

/// Sets up flutter_skill in the target project.
///
/// When [quiet] is true, all status output is suppressed — use this when
/// calling from the MCP server to avoid polluting the JSON-RPC stdout stream.
Future<void> runSetup(String projectPath, {bool quiet = false}) async {
  void log(String msg) {
    if (!quiet) print(msg);
  }

  final pubspecFile = File('$projectPath/pubspec.yaml');
  final mainFile = File('$projectPath/lib/main.dart');

  if (!pubspecFile.existsSync()) {
    log('Error: pubspec.yaml not found at $projectPath');
    if (!quiet) exit(1);
    throw Exception('pubspec.yaml not found at $projectPath');
  }

  if (!mainFile.existsSync()) {
    log('Error: lib/main.dart not found at $projectPath');
    if (!quiet) exit(1);
    throw Exception('lib/main.dart not found at $projectPath');
  }

  log('Checking dependencies in ${pubspecFile.path}...');
  final pubspecContent = pubspecFile.readAsStringSync();

  final flutterCmd = Platform.isWindows ? 'flutter.bat' : 'flutter';

  if (!pubspecContent.contains('flutter_skill:')) {
    log('Adding flutter_skill dependency...');
    final result = await Process.run(
      flutterCmd,
      ['pub', 'add', 'flutter_skill'],
      workingDirectory: projectPath,
      runInShell: Platform.isWindows,
    );
    if (result.exitCode != 0) {
      log('Failed to add dependency: ${result.stderr}');
      if (!quiet) exit(1);
      throw Exception('Failed to add dependency: ${result.stderr}');
    }
    log('✅ flutter_skill dependency added.');
  } else {
    // Dependency exists, check if it needs update
    log('flutter_skill dependency found. Checking for updates...');

    // Use flutter pub upgrade to get the latest version
    final upgradeResult = await Process.run(
      flutterCmd,
      ['pub', 'upgrade', 'flutter_skill'],
      workingDirectory: projectPath,
      runInShell: Platform.isWindows,
    );

    if (upgradeResult.exitCode == 0) {
      final output = upgradeResult.stdout.toString();
      if (output.contains('Changed') || output.contains('flutter_skill')) {
        log('✅ flutter_skill updated to latest version.');
      } else {
        log('✅ flutter_skill is already up to date.');
      }
    } else {
      log('⚠️  Failed to check for updates: ${upgradeResult.stderr}');
      log('Continuing with existing version...');
    }
  }

  log('Checking instrumentation in ${mainFile.path}...');
  String mainContent = mainFile.readAsStringSync();

  bool changed = false;

  // 1. Check Import
  if (!mainContent.contains('package:flutter_skill/flutter_skill.dart')) {
    mainContent =
        "import 'package:flutter_skill/flutter_skill.dart';\nimport 'package:flutter/foundation.dart'; // For kDebugMode\n" +
            mainContent;
    changed = true;
    log('Added imports.');
  }

  // 2. Check Initialization
  if (!mainContent.contains('FlutterSkillBinding.ensureInitialized()')) {
    final mainRegex = RegExp(r'void\s+main\s*\(\s*\)\s*\{');
    final match = mainRegex.firstMatch(mainContent);

    if (match != null) {
      final end = match.end;
      const injection =
          '\n  if (kDebugMode) {\n    FlutterSkillBinding.ensureInitialized();\n  }\n';
      mainContent = mainContent.replaceRange(end, end, injection);
      changed = true;
      log('Added FlutterSkillBinding initialization.');
    } else {
      log('Warning: Could not find "void main() {" to inject code. Manual setup required.');
    }
  }

  if (changed) {
    mainFile.writeAsStringSync(mainContent);
    log('Updated lib/main.dart.');
  } else {
    log('No changes needed for lib/main.dart.');
  }

  log('Setup complete.');
}
