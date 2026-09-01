import 'dart:convert';
import 'dart:io';
import 'setup.dart'; // Import setup logic
import '../drivers/flutter_driver.dart';
import '../skill_server.dart';

Future<void> runLaunch(List<String> args) async {
  // Extract project path and new flags before passing the rest to flutter run.
  //
  // New flags (consumed here, not forwarded to flutter):
  //   --id=<name>    Register the attached skill server under this name.
  //   --detach       Spawn a detached child process that keeps the server alive;
  //                  the parent process exits after handing off.

  String projectPath = '.';
  String? serverId;
  bool detach = false;
  List<String> flutterArgs = [];

  for (int i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg.startsWith('--id=')) {
      serverId = arg.substring('--id='.length);
    } else if (arg == '--detach') {
      detach = true;
    } else if (i == 0 && !arg.startsWith('-')) {
      projectPath = arg;
    } else {
      flutterArgs.add(arg);
    }
  }

  print('Running auto-setup...');
  try {
    // Call the setup logic directly
    await runSetup(projectPath);
  } catch (e) {
    print('Setup failed: $e');
    print('Proceeding with launch anyway...');
  }

  // Auto-add --vm-service-port=50000 if not specified.
  // This ensures faster discovery (recommended but not required).
  if (!flutterArgs.any((arg) => arg.contains('--vm-service-port'))) {
    flutterArgs.add('--vm-service-port=50000');
    print('Auto-adding --vm-service-port=50000 (recommended for faster discovery)');
  }

  print('Launching Flutter app in: $projectPath with args: $flutterArgs');

  final flutterCmd = Platform.isWindows ? 'flutter.bat' : 'flutter';
  final process = await Process.start(
    flutterCmd,
    ['run', ...flutterArgs],
    workingDirectory: projectPath,
    mode: ProcessStartMode.normal,
    runInShell: Platform.isWindows,
  );

  print(
      'Flutter process started (PID: ${process.pid}). Waiting for connection URI...');

  String? discoveredUri;

  process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
    print('[Flutter]: $line');
    final uri = _extractUri(line);
    if (uri != null && discoveredUri == null) {
      discoveredUri = uri;
      _onUriDiscovered(uri, serverId, projectPath, detach, process);
    }
  });

  process.stderr
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
    print('[Flutter Error]: $line');
  });

  // Forward stdin to flutter run
  if (stdin.hasTerminal) {
    stdin.listen((data) => process.stdin.add(data));
  }

  final exitCode = await process.exitCode;
  print('Flutter app exited with code $exitCode');
  exit(exitCode);
}

String? _extractUri(String line) {
  // Try ws:// first (most common)
  final wsMatch = RegExp(r'ws://[^\s]+').firstMatch(line);
  if (wsMatch != null) return wsMatch.group(0);
  // Also match http:// VM Service URIs (newer Flutter versions)
  final httpMatch = RegExp(r'http://127\.0\.0\.1:\d+[^\s]*').firstMatch(line);
  return httpMatch?.group(0);
}

void _onUriDiscovered(
    String uri, String? serverId, String projectPath, bool detach, Process process) {
  print('\nFlutter Skill: VM Service is ready');
  print('   URI: $uri');
  print('   Run: flutter_skill inspect  (auto-discovery)');

  if (serverId == null) return;

  if (detach) {
    // Spawn a detached helper process that owns the SkillServer lifecycle.
    // The parent (this process) continues owning `flutter run`.
    _spawnDetachedServer(serverId, uri, projectPath);
  } else {
    // Attach the SkillServer in-process (background isolate via async).
    _attachServer(serverId, uri, projectPath, process);
  }
}

/// Attach a SkillServer in the same process (async, non-blocking).
void _attachServer(String id, String uri, String projectPath, Process process) async {
  try {
    final driver = FlutterSkillClient(uri);
    await driver.connect();
    final server = SkillServer(id: id, driver: driver, projectPath: projectPath);
    await server.start();
    print('Skill server "$id" listening on port ${server.port}');

    // Write a convenience file in the project directory.
    final marker = File('$projectPath/.flutter_skill_server');
    await marker.writeAsString(id, flush: true);

    // Stop the skill server when flutter run exits.
    process.exitCode.then((_) async {
      await server.stop().catchError((_) {});
    });
  } catch (e) {
    print('Warning: Could not start skill server "$id": $e');
  }
}

/// Spawn a completely detached child process to host the SkillServer.
void _spawnDetachedServer(String id, String uri, String projectPath) {
  // We re-invoke ourselves with the `connect` command so the child process
  // manages the server lifecycle independently.
  final exe = Platform.executable; // The binary that was actually invoked.
  final script = Platform.script.toFilePath();

  // When running via `dart run` or `dart <script>`, executable is the Dart VM
  // binary. Re-invoke as: dart <script> connect ...
  // When compiled/globally activated, exe IS the flutter_skill binary.
  final List<String> cmdArgs;
  if (exe.endsWith('dart') || exe.endsWith('dart.exe')) {
    if (script.isNotEmpty && script.endsWith('.dart')) {
      cmdArgs = [script, 'connect', '--id=$id', '--uri=$uri', '--project=$projectPath'];
    } else {
      // Snapshot or other — best effort.
      cmdArgs = ['run', 'bin/flutter_skill.dart', 'connect', '--id=$id', '--uri=$uri', '--project=$projectPath'];
    }
  } else {
    cmdArgs = ['connect', '--id=$id', '--uri=$uri', '--project=$projectPath'];
  }

  Process.start(
    exe,
    cmdArgs,
    mode: ProcessStartMode.detached,
    runInShell: false,
  ).then((p) {
    print('Detached skill server "$id" started (PID: ${p.pid})');
    final marker = File('$projectPath/.flutter_skill_server');
    marker.writeAsString(id, flush: true).catchError((_) => marker);
  }).catchError((e) {
    print('Warning: Could not start detached server "$id": $e');
  });
}
