import 'dart:convert';
import 'dart:io';

import 'output_format.dart';

/// Run the `flutter_skill ping` command.
///
/// Usage: flutter_skill ping --server=<id>[,<id2>,...]
///
/// Sends a ping request to one or more named skill servers and prints the
/// result. Exits with code 1 if any server is unreachable.
Future<void> runPing(List<String> args) async {
  final serverIds = parseServerIds(args);
  if (serverIds.isEmpty) {
    print('Usage: flutter_skill ping --server=<id>[,<id2>,...]');
    exit(1);
  }
  final results = await callServersParallel(serverIds, 'ping', {});
  final format = resolveOutputFormat(args);
  if (format == OutputFormat.json) {
    print(jsonEncode(results.map((r) => r.toJson()).toList()));
  } else {
    for (final r in results) {
      if (r.success) {
        print('[${r.serverId}] pong (${r.durationMs}ms)');
      } else {
        print('[${r.serverId}] unreachable: ${r.error}');
      }
    }
  }
  if (results.any((r) => !r.success)) exit(1);
}
