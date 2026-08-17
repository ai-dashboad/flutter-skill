part of '../server.dart';

extension _BfNavigation on FlutterMcpServer {
  Future<dynamic> _handleNavigationTool(
      String name, Map<String, dynamic> args, AppDriver? client) async {
    switch (name) {
      case 'get_current_route':
        if (client is BridgeDriver) {
          final route = await client.getRoute();
          return {"route": route};
        }
        final fc = _asFlutterClient(client!, 'get_current_route');
        // Always a map: a bare null would read as "tool not handled".
        return await fc.getCurrentRouteInfo();
      case 'go_back':
        final count = (args['count'] as num?)?.toInt() ?? 1;
        var steps = 0;
        for (var i = 0; i < count; i++) {
          bool ok;
          if (client is BridgeDriver) {
            ok = await client.goBack();
          } else {
            final fc = _asFlutterClient(client!, 'go_back');
            ok = await fc.goBack();
          }
          if (!ok) break;
          steps++;
          if (i < count - 1) {
            // Brief pause so the route transition completes before next pop
            await Future.delayed(const Duration(milliseconds: 300));
          }
        }
        if (steps == 0) return {"success": false, "message": "Cannot go back"};
        return {
          "success": true,
          "message": steps == count
              ? "Navigated back $steps step${steps > 1 ? 's' : ''}"
              : "Navigated back $steps of $count steps (reached root)",
          "steps": steps,
        };
      case 'get_navigation_stack':
        if (client is BridgeDriver) {
          return await client.callMethod('get_navigation_stack');
        }
        final fc = _asFlutterClient(client!, 'get_navigation_stack');
        return await fc.getNavigationStack();

      // Debug & Logs
      default:
        return null;
    }
  }
}
