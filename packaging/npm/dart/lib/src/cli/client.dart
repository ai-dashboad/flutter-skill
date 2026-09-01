import 'dart:convert';
import 'dart:io';

/// CLI client for flutter-skill serve API.
/// Connects to a running serve instance and calls tools.
class ServeClient {
  final String host;
  final int port;
  final HttpClient _client = HttpClient();

  ServeClient({this.host = '127.0.0.1', this.port = 3000}) {
    _client.connectionTimeout = const Duration(seconds: 5);
  }

  String get baseUrl => 'http://$host:$port';

  /// Call a tool on the serve API.
  Future<Map<String, dynamic>> call(
      String toolName, Map<String, dynamic> args) async {
    try {
      final uri = Uri.parse('$baseUrl/tools/call');
      final request = await _client.postUrl(uri);
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({'name': toolName, 'arguments': args}));
      final response = await request.close().timeout(
            const Duration(seconds: 30),
          );
      final body = await response.transform(utf8.decoder).join();
      return jsonDecode(body) as Map<String, dynamic>;
    } catch (e) {
      return {'error': e.toString()};
    }
  }

  /// List available tools.
  Future<List<dynamic>> listTools() async {
    try {
      final uri = Uri.parse('$baseUrl/tools/list');
      final request = await _client.getUrl(uri);
      final response = await request.close().timeout(
            const Duration(seconds: 5),
          );
      final body = await response.transform(utf8.decoder).join();
      final data = jsonDecode(body);
      return data is List ? data : (data['tools'] ?? []);
    } catch (e) {
      return [];
    }
  }

  /// Check if serve is running.
  Future<bool> isRunning() async {
    try {
      final tools = await listTools();
      return tools.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  void close() => _client.close();
}

/// Parse --port=N and --host=H from args, return remaining args.
({ServeClient client, List<String> rest}) parseClientArgs(List<String> args) {
  int port = 3000;
  String host = '127.0.0.1';
  final rest = <String>[];

  for (final arg in args) {
    if (arg.startsWith('--port=')) {
      port = int.parse(arg.substring(7));
    } else if (arg.startsWith('--host=')) {
      host = arg.substring(7);
    } else {
      rest.add(arg);
    }
  }

  // Also check FS_PORT / FS_HOST env vars
  final envPort = Platform.environment['FS_PORT'];
  final envHost = Platform.environment['FS_HOST'];
  if (envPort != null) port = int.parse(envPort);
  if (envHost != null) host = envHost;

  return (client: ServeClient(host: host, port: port), rest: rest);
}

/// Run a CLI client command.
Future<void> runClient(String command, List<String> args) async {
  final parsed = parseClientArgs(args);
  final client = parsed.client;
  final rest = parsed.rest;

  try {
    // Check connection first
    if (!await client.isRunning()) {
      stderr.writeln(
          'Error: flutter-skill serve not running on ${client.baseUrl}');
      stderr.writeln('Start it with: flutter-skill serve <url>');
      exit(1);
    }

    switch (command) {
      case 'nav':
      case 'navigate':
      case 'go':
        if (rest.isEmpty) {
          stderr.writeln('Usage: flutter-skill nav <url>');
          exit(1);
        }
        final r = await client.call('navigate', {'url': rest[0]});
        _printJson(r);
        break;

      case 'snap':
      case 'snapshot':
        final r = await client.call('snapshot', {});
        if (r.containsKey('snapshot')) {
          stdout.write(r['snapshot']);
        } else {
          _printJson(r);
        }
        break;

      case 'screenshot':
      case 'ss':
        final r = await client.call('screenshot', {});
        if (r.containsKey('base64')) {
          final path = rest.isNotEmpty ? rest[0] : '/tmp/screenshot.jpg';
          File(path).writeAsBytesSync(base64Decode(r['base64']));
          print('saved $path (${File(path).lengthSync()} bytes)');
        } else {
          _printJson(r);
        }
        break;

      case 'tap':
        if (rest.isEmpty) {
          stderr.writeln('Usage: flutter-skill tap <text|ref> OR tap <x> <y>');
          exit(1);
        }
        Map<String, dynamic> tapArgs;
        if (rest.length >= 2 && _isNumeric(rest[0])) {
          tapArgs = {'x': double.parse(rest[0]), 'y': double.parse(rest[1])};
        } else if (rest[0].startsWith('e') &&
            _isNumeric(rest[0].substring(1))) {
          tapArgs = {'ref': rest[0]};
        } else {
          tapArgs = {'text': rest.join(' ')};
        }
        final r = await client.call('tap', tapArgs);
        _printJson(r);
        break;

      case 'type':
        if (rest.isEmpty) {
          stderr.writeln('Usage: flutter-skill type <text>');
          exit(1);
        }
        final r = await client.call('type_text', {'text': rest.join(' ')});
        _printJson(r);
        break;

      case 'key':
      case 'press':
        if (rest.isEmpty) {
          stderr.writeln('Usage: flutter-skill key <key> [modifiers]');
          exit(1);
        }
        final keyArgs = <String, dynamic>{'key': rest[0]};
        if (rest.length > 1) keyArgs['modifiers'] = rest[1];
        final r = await client.call('press_key', keyArgs);
        _printJson(r);
        break;

      case 'eval':
      case 'js':
        if (rest.isEmpty) {
          stderr.writeln('Usage: flutter-skill eval <expression>');
          exit(1);
        }
        final r = await client.call('evaluate', {'expression': rest.join(' ')});
        if (r.containsKey('result')) {
          final result = r['result'];
          if (result is String) {
            print(result);
          } else {
            print(jsonEncode(result));
          }
        } else {
          _printJson(r);
        }
        break;

      case 'title':
        final r = await client.call('get_title', {});
        print(r['title'] ?? jsonEncode(r));
        break;

      case 'text':
        final r = await client.call('get_text', {});
        print(r['text'] ?? jsonEncode(r));
        break;

      case 'hover':
        if (rest.isEmpty) {
          stderr.writeln('Usage: flutter-skill hover <text>');
          exit(1);
        }
        final r = await client.call('hover', {'text': rest.join(' ')});
        _printJson(r);
        break;

      case 'upload':
        if (rest.length < 2) {
          stderr.writeln(
              'Usage: flutter-skill upload <selector|auto> <file_path>');
          exit(1);
        }
        final r = await client
            .call('upload_file', {'selector': rest[0], 'file_path': rest[1]});
        _printJson(r);
        break;

      case 'tools':
        final tools = await client.listTools();
        for (final t in tools) {
          if (t is Map) {
            print(t['name'] ?? t);
          } else {
            print(t);
          }
        }
        print('\n${tools.length} tools');
        break;

      case 'call':
        if (rest.isEmpty) {
          stderr.writeln('Usage: flutter-skill call <tool> [json_args]');
          exit(1);
        }
        final toolArgs = rest.length > 1
            ? jsonDecode(rest[1]) as Map<String, dynamic>
            : <String, dynamic>{};
        final r = await client.call(rest[0], toolArgs);
        _printJson(r);
        break;

      case 'wait':
        final ms = rest.isNotEmpty ? int.parse(rest[0]) : 1000;
        await Future.delayed(Duration(milliseconds: ms));
        print('ok');
        break;

      default:
        // Try as raw tool call
        final toolArgs = rest.isNotEmpty && rest[0].startsWith('{')
            ? jsonDecode(rest[0]) as Map<String, dynamic>
            : <String, dynamic>{};
        final r = await client.call(command, toolArgs);
        _printJson(r);
    }
  } finally {
    client.close();
  }
}

bool _isNumeric(String s) => double.tryParse(s.replaceAll('-', '')) != null;

void _printJson(Map<String, dynamic> data) {
  if (data.containsKey('error')) {
    stderr.writeln('Error: ${data['error']}');
  } else {
    print(jsonEncode(data));
  }
}
