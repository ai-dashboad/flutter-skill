import 'dart:convert';
import 'dart:io';

import '../server_registry.dart';
import '../skill_client.dart';
import 'output_format.dart';

/// CLI command: `flutter_skill server <subcommand> [options]`
///
/// Subcommands:
///   list                        — table of running named servers
///   stop  --id=<name>           — stop a named server
///   status --id=<name>          — show status of a named server
Future<void> runServerCmd(List<String> args) async {
  final format = resolveOutputFormat(args);
  final cleanArgs = stripOutputFormatFlag(args);

  final sub = cleanArgs.isNotEmpty ? cleanArgs[0] : 'list';
  final subArgs = cleanArgs.length > 1 ? cleanArgs.sublist(1) : <String>[];

  switch (sub) {
    case 'list':
      await _cmdList(format);
      break;
    case 'stop':
      await _cmdStop(subArgs, format);
      break;
    case 'status':
      await _cmdStatus(subArgs, format);
      break;
    default:
      print('Unknown server subcommand: $sub');
      print('Available: list, stop, status');
      exit(1);
  }
}

// ---------------------------------------------------------------------------
// list
// ---------------------------------------------------------------------------

Future<void> _cmdList(OutputFormat format) async {
  await ServerRegistry.prune(); // Clean stale entries before listing.
  final entries = await ServerRegistry.listAll();

  if (format == OutputFormat.json) {
    print(jsonEncode(entries.map((e) => e.toJson()).toList()));
    return;
  }

  if (entries.isEmpty) {
    print('No running skill servers found.');
    return;
  }

  // Human-readable table.
  print('Running skill servers:');
  print('');
  final header = 'ID'.padRight(20) +
      'PORT'.padRight(8) +
      'PID'.padRight(8) +
      'PROJECT';
  print(header);
  print('-' * 60);
  for (final e in entries) {
    final alive = await ServerRegistry.isAlive(e.id);
    final status = alive ? '' : ' (unreachable)';
    print(e.id.padRight(20) +
        e.port.toString().padRight(8) +
        e.pid.toString().padRight(8) +
        e.projectPath +
        status);
  }
}

// ---------------------------------------------------------------------------
// stop
// ---------------------------------------------------------------------------

Future<void> _cmdStop(List<String> args, OutputFormat format) async {
  final id = _parseFlag(args, '--id');
  if (id == null) {
    print('Usage: flutter_skill server stop --id=<name>');
    exit(1);
  }

  // Send a JSON-RPC shutdown request — or just unregister if unreachable.
  // When shutdown succeeds, the server process exits itself (and cleans its
  // own registry entry). Only unregister manually in the catch path.
  bool sent = false;
  try {
    final client = SkillClient.byId(id);
    await client.call('shutdown', {});
    sent = true;
  } catch (_) {
    // Server unreachable — clean the registry entry manually.
    await ServerRegistry.unregister(id);
  }

  if (format == OutputFormat.json) {
    print(jsonEncode({'id': id, 'stopped': true, 'signaled': sent}));
  } else {
    print(sent
        ? 'Server "$id" stopped.'
        : 'Server "$id" was not reachable; registry entry removed.');
  }
}

// ---------------------------------------------------------------------------
// status
// ---------------------------------------------------------------------------

Future<void> _cmdStatus(List<String> args, OutputFormat format) async {
  final id = _parseFlag(args, '--id');
  if (id == null) {
    print('Usage: flutter_skill server status --id=<name>');
    exit(1);
  }

  final entry = await ServerRegistry.get(id);
  if (entry == null) {
    if (format == OutputFormat.json) {
      print(jsonEncode({'id': id, 'found': false}));
    } else {
      print('No server registered with id "$id".');
    }
    return;
  }

  final alive = await ServerRegistry.isAlive(id);

  if (format == OutputFormat.json) {
    final data = entry.toJson();
    data['alive'] = alive;
    print(jsonEncode(data));
    return;
  }

  print('Server: ${entry.id}');
  print('  Status  : ${alive ? "running" : "unreachable"}');
  print('  Port    : ${entry.port}');
  print('  PID     : ${entry.pid}');
  print('  Project : ${entry.projectPath}');
  print('  Device  : ${entry.deviceId}');
  print('  URI     : ${entry.vmServiceUri}');
  print('  Started : ${entry.startedAt.toLocal()}');
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

String? _parseFlag(List<String> args, String flag) {
  for (final arg in args) {
    if (arg.startsWith('$flag=')) return arg.substring(flag.length + 1);
  }
  return null;
}
