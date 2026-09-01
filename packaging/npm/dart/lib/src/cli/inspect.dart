import 'dart:convert';
import 'dart:io';
import '../drivers/flutter_driver.dart';
import 'output_format.dart';

Future<void> runInspect(List<String> args) async {
  // --server=<id>[,<id2>,...] — forward to named SkillServer instance(s)
  // --output=json|human       — output format
  final serverIds = parseServerIds(args);
  final format = resolveOutputFormat(args);
  final cleanArgs =
      stripOutputFormatFlag(args).where((a) => !a.startsWith('--server=')).toList();

  if (serverIds.isNotEmpty) {
    await _inspectViaServers(serverIds, format);
    return;
  }

  // Default behaviour: direct VM Service connection.
  String uri;
  try {
    uri = await FlutterSkillClient.resolveUri(cleanArgs);
  } catch (e) {
    print(e);
    exit(1);
  }

  final client = FlutterSkillClient(uri);

  try {
    await client.connect();
    final elements = await client.getInteractiveElements();

    if (format == OutputFormat.json) {
      print(jsonEncode({'elements': elements}));
    } else {
      // Print simplified tree for LLM consumption
      print('Interactive Elements:');
      if (elements.isEmpty) {
        print('(No interactive elements found)');
      } else {
        for (final e in elements) {
          _printElement(e);
        }
      }
    }
  } catch (e) {
    print('Error: $e');
    exit(1);
  } finally {
    await client.disconnect();
  }
}

/// Forward the inspect action to one or more named servers concurrently.
Future<void> _inspectViaServers(
    List<String> serverIds, OutputFormat format) async {
  final results = await callServersParallel(serverIds, 'inspect', {});

  if (format == OutputFormat.json) {
    if (serverIds.length == 1) {
      // Single server: unwrap to match direct-VM schema {"elements": [...]}
      final r = results.first;
      if (r.success) {
        print(jsonEncode(r.data ?? {'elements': []}));
      } else {
        print(jsonEncode({'error': r.error}));
      }
    } else {
      print(jsonEncode(results.map((r) => r.toJson()).toList()));
    }
    return;
  }

  // Human output: always show server prefix for clarity
  for (final r in results) {
    if (!r.success) {
      print('[${r.serverId}] Error: ${r.error}');
      continue;
    }
    final elements = (r.data?['elements'] as List?) ?? [];
    final prefix = serverIds.length > 1 ? '[${r.serverId}] ' : '';
    print('${prefix}Interactive Elements (${r.durationMs}ms):');
    if (elements.isEmpty) {
      print('  (No interactive elements found)');
    } else {
      for (final e in elements) {
        _printElement(e, prefix: '  ');
      }
    }
  }
}

void _printElement(dynamic element, {String prefix = ''}) {
  if (element is! Map) return;

  // Try to extract useful info
  final type = element['type'] ?? 'Widget';
  final key = element['key'];
  final text = element['text'];
  final tooltip = element['tooltip'];

  var buffer = StringBuffer();
  buffer.write(prefix);
  buffer.write('- **$type**');

  if (key != null) buffer.write(' [Key: "$key"]');
  if (text != null && text.toString().isNotEmpty)
    buffer.write(' [Text: "$text"]');
  if (tooltip != null) buffer.write(' [Tooltip: "$tooltip"]');

  print(buffer.toString());

  // Recursively print children if any
  if (element.containsKey('children') && element['children'] is List) {
    for (final child in element['children']) {
      _printElement(child, prefix: '$prefix  ');
    }
  }
}

