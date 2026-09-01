import 'dart:io';

/// Setup tool priority rules for Claude Code
Future<void> runSetupPriority(List<String> args) async {
  final force = args.contains('--force');
  final silent = args.contains('--silent');

  if (!silent) {
    print('🚀 Setting up flutter-skill tool priority rules...\n');
  }

  // Get project root (where this script is located)
  final scriptPath = Platform.script.toFilePath();
  final binDir = Directory(scriptPath).parent;
  final projectRoot = binDir.parent;
  final promptsSourceDir = Directory('${projectRoot.path}/docs/prompts');
  final sourceFile = File('${promptsSourceDir.path}/tool-priority.md');

  // Claude Code prompts directory
  final homeDir =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  if (homeDir == null) {
    stderr.writeln('❌ Error: Could not determine home directory');
    exit(1);
  }

  final claudeDir = Directory('$homeDir/.claude');
  final claudePrompts = Directory('${claudeDir.path}/prompts');
  final targetFile = File('${claudePrompts.path}/flutter-tool-priority.md');

  // Check if source file exists
  if (!sourceFile.existsSync()) {
    stderr.writeln('❌ Error: Source file not found: ${sourceFile.path}');
    stderr.writeln(
        '   Make sure you\'re running this from the flutter-skill project directory');
    exit(1);
  }

  // Check if already installed
  if (targetFile.existsSync() && !force) {
    if (!silent) {
      print('✅ Tool priority rules already installed!');
      print('   Location: ${targetFile.path}');
      print('   Use --force to reinstall\n');
    }
    return;
  }

  // Create directories
  if (!claudePrompts.existsSync()) {
    claudePrompts.createSync(recursive: true);
    if (!silent) {
      print('📁 Created directory: ${claudePrompts.path}');
    }
  }

  // Copy file
  try {
    sourceFile.copySync(targetFile.path);
    if (!silent) {
      print('✅ Tool priority rules installed!\n');
      print('Installed to:');
      print('  ${targetFile.path}\n');
      print('📝 What this does:');
      print(
          '  • Claude Code will now ALWAYS prioritize flutter-skill over Dart MCP');
      print('  • Applies to ALL Flutter testing scenarios');
      print('  • No manual tool selection needed\n');
      print('✨ Ready to use!');
      print(
          'Next time you ask Claude to test a Flutter app, it will automatically:');
      print('  1. Use flutter-skill tools');
      print('  2. Add --vm-service-port=50000 flag');
      print('  3. Never suggest Dart MCP for Flutter testing\n');
    }
  } catch (e) {
    stderr.writeln('❌ Error installing rules: $e');
    exit(1);
  }
}

/// Check if tool priority rules are installed
bool isToolPriorityInstalled() {
  final homeDir =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  if (homeDir == null) return false;

  final targetFile = File('$homeDir/.claude/prompts/flutter-tool-priority.md');
  return targetFile.existsSync();
}

/// Show setup reminder if not installed
void showSetupReminder() {
  if (!isToolPriorityInstalled()) {
    print('');
    print(
        '💡 Tip: Install tool priority rules for better Claude Code integration');
    print('   Run: flutter_skill setup');
    print(
        '   This ensures Claude always uses flutter-skill instead of Dart MCP\n');
  }
}
