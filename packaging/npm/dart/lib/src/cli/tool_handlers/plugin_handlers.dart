part of '../server.dart';

extension _PluginHandlers on FlutterMcpServer {
  Future<void> _loadPlugins() async {
    final dir = Directory(_pluginsDir);
    if (!await dir.exists()) {
      return; // No plugins directory — normal on fresh install, silently skip
    }
    await for (final entity in dir.list()) {
      if (entity is File && entity.path.endsWith('.json')) {
        try {
          final content = await entity.readAsString();
          final plugin = jsonDecode(content) as Map<String, dynamic>;
          final name = plugin['name'] as String?;
          final description =
              plugin['description'] as String? ?? 'Custom plugin';
          final steps = (plugin['steps'] as List<dynamic>?) ?? [];
          if (name == null || steps.isEmpty) continue;
          _pluginTools.add({
            'name': name,
            'description': description,
            'steps': steps,
            'source': entity.path,
          });
          stderr.writeln('Loaded plugin: $name (${steps.length} steps)');
        } catch (e) {
          stderr.writeln('Failed to load plugin ${entity.path}: $e');
        }
      }
    }
    if (_pluginTools.isNotEmpty) {
      stderr.writeln('Loaded ${_pluginTools.length} plugin(s)');
    }
  }

  /// Execute a plugin by running its steps sequentially
  Future<dynamic> _executePlugin(
      Map<String, dynamic> plugin, Map<String, dynamic> args) async {
    final steps = (plugin['steps'] as List<dynamic>);
    final results = <Map<String, dynamic>>[];
    for (int i = 0; i < steps.length; i++) {
      final step = steps[i] as Map<String, dynamic>;
      final toolName = step['tool'] as String;
      final toolArgs = Map<String, dynamic>.from(
          (step['args'] as Map<String, dynamic>?) ?? {});
      // Allow overriding step args from the call args
      toolArgs.addAll(args);
      final stopwatch = Stopwatch()..start();
      try {
        final result = await _executeToolInner(toolName, toolArgs);
        stopwatch.stop();
        results.add({
          'step': i + 1,
          'tool': toolName,
          'success': true,
          'result': result,
          'duration_ms': stopwatch.elapsedMilliseconds,
        });
      } catch (e) {
        stopwatch.stop();
        results.add({
          'step': i + 1,
          'tool': toolName,
          'success': false,
          'error': e.toString(),
          'duration_ms': stopwatch.elapsedMilliseconds,
        });
        break;
      }
    }
    final passed = results.where((r) => r['success'] == true).length;
    return {
      'plugin': plugin['name'],
      'steps_total': steps.length,
      'steps_executed': results.length,
      'steps_passed': passed,
      'success': passed == results.length,
      'results': results,
    };
  }
}
