part of '../server.dart';

extension _BfState on FlutterMcpServer {
  Future<dynamic> _handleStateTool(
      String name, Map<String, dynamic> args, AppDriver? client) async {
    switch (name) {
      case 'get_page_state':
        if (client is BridgeDriver) {
          final route = await client.getRoute();
          final structured = await client.getInteractiveElementsStructured();
          return {"route": route, "elements": structured};
        }
        final fc = _asFlutterClient(client!, 'get_page_state');
        return await _getPageState(fc);

      case 'get_interactable_elements':
        final includePositions = args['include_positions'] ?? true;
        return await client!
            .getInteractiveElements(includePositions: includePositions);

      // === NEW: Performance & Memory ===
      case 'get_frame_stats':
        if (client is BridgeDriver) {
          return await client.callMethod('get_frame_stats');
        }
        final fc = _asFlutterClient(client!, 'get_frame_stats');
        return await fc.getFrameStats();

      case 'get_memory_stats':
        if (client is BridgeDriver) {
          return await client.callMethod('get_memory_stats');
        }
        final fc = _asFlutterClient(client!, 'get_memory_stats');
        return await fc.getMemoryStats();

      // === Smart Diagnosis ===
      case 'diagnose':
        if (client is BridgeDriver) {
          return await client.callMethod('diagnose', args);
        }
        final fc = _asFlutterClient(client!, 'diagnose');
        return await _performDiagnosis(args, fc);

      case 'list_plugins':
        return {
          'plugins': _pluginTools
              .map((p) => {
                    'name': p['name'],
                    'description': p['description'],
                    'steps': (p['steps'] as List).length,
                    'source': p['source'],
                  })
              .toList(),
          'count': _pluginTools.length,
        };

      case 'generate_report':
        return await _generateReport(args);

      default:
        // Check plugin tools
        final plugin = _pluginTools.cast<Map<String, dynamic>?>().firstWhere(
              (p) => p!['name'] == name,
              orElse: () => null,
            );
        if (plugin != null) {
          return await _executePlugin(plugin, args);
        }
        return null;
    }
  }
}
