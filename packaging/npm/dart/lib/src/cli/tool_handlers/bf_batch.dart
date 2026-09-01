part of '../server.dart';

extension _BfBatch on FlutterMcpServer {
  Future<dynamic> _handleBatchCoordTool(
      String name, Map<String, dynamic> args, AppDriver? client) async {
    switch (name) {
      case 'execute_batch':
        if (client is BridgeDriver) {
          final actions = args['actions'] as List? ?? [];
          final results = <Map<String, dynamic>>[];
          for (final action in actions) {
            if (action is Map<String, dynamic>) {
              final toolName = action['tool'] as String?;
              final toolArgs =
                  Map<String, dynamic>.from(action['args'] as Map? ?? {});
              if (toolName != null) {
                try {
                  final result = await client.callMethod(toolName, toolArgs);
                  results.add(
                      {'tool': toolName, 'success': true, 'result': result});
                } catch (e) {
                  results.add({
                    'tool': toolName,
                    'success': false,
                    'error': e.toString()
                  });
                }
              }
            }
          }
          return {"success": true, "results": results, "count": results.length};
        }
        final fc = _asFlutterClient(client!, 'execute_batch');
        return await _executeBatch(args, fc);

      // === NEW: Coordinate-based Actions ===
      case 'tap_at':
        if (client is BridgeDriver) {
          await client.callMethod('tap_at', {
            'x': (args['x'] as num).toDouble(),
            'y': (args['y'] as num).toDouble()
          });
          return {
            "success": true,
            "action": "tap_at",
            "x": args['x'],
            "y": args['y']
          };
        }
        final fc = _asFlutterClient(client!, 'tap_at');
        final x = (args['x'] as num).toDouble();
        final y = (args['y'] as num).toDouble();
        final tapped = await fc.tapAt(x, y);
        return {
          "success": true,
          "action": "tap_at",
          "x": x,
          "y": y,
          if (tapped['warning'] != null) "warning": tapped['warning'],
        };

      case 'long_press_at':
        if (client is BridgeDriver) {
          await client.callMethod('long_press_at', {
            'x': (args['x'] as num).toDouble(),
            'y': (args['y'] as num).toDouble(),
            'duration': args['duration'] ?? 500
          });
          return {
            "success": true,
            "action": "long_press_at",
            "x": args['x'],
            "y": args['y']
          };
        }
        final fc = _asFlutterClient(client!, 'long_press_at');
        final x = (args['x'] as num).toDouble();
        final y = (args['y'] as num).toDouble();
        final duration = args['duration'] ?? 500;
        await fc.longPressAt(x, y, duration: duration);
        return {"success": true, "action": "long_press_at", "x": x, "y": y};

      case 'swipe_coordinates':
        if (client is BridgeDriver) {
          await client.callMethod('swipe_coordinates', {
            'start_x': ((args['start_x'] ?? args['startX']) as num).toDouble(),
            'start_y': ((args['start_y'] ?? args['startY']) as num).toDouble(),
            'end_x': ((args['end_x'] ?? args['endX']) as num).toDouble(),
            'end_y': ((args['end_y'] ?? args['endY']) as num).toDouble(),
            'duration': args['duration'] ?? args['durationMs'] ?? 300,
          });
          return {"success": true, "action": "swipe_coordinates"};
        }
        final fc = _asFlutterClient(client!, 'swipe_coordinates');
        final startX = ((args['start_x'] ?? args['startX']) as num).toDouble();
        final startY = ((args['start_y'] ?? args['startY']) as num).toDouble();
        final endX = ((args['end_x'] ?? args['endX']) as num).toDouble();
        final endY = ((args['end_y'] ?? args['endY']) as num).toDouble();
        final duration = args['duration'] ?? 300;
        await fc.swipeCoordinates(startX, startY, endX, endY,
            duration: duration);
        return {"success": true, "action": "swipe_coordinates"};

      case 'edge_swipe':
        if (client is BridgeDriver) {
          return await client.callMethod('edge_swipe', {
            'edge': args['edge'],
            'direction': args['direction'],
            'distance': (args['distance'] as num?)?.toDouble() ?? 200
          });
        }
        final fc = _asFlutterClient(client!, 'edge_swipe');
        final edge = args['edge'] as String? ?? 'left';
        final direction = args['direction'] as String? ?? 'right';
        final distance = (args['distance'] as num?)?.toDouble() ?? 200;
        final result = await fc.edgeSwipe(
            edge: edge, direction: direction, distance: distance);
        return result;

      case 'gesture':
        if (client is BridgeDriver) {
          return await client.callMethod('gesture', args);
        }
        final fc = _asFlutterClient(client!, 'gesture');
        return await _performGesture(args, fc);

      case 'wait_for_idle':
        if (client is BridgeDriver) {
          return {"success": true, "message": "Bridge platform ready"};
        }
        final fc = _asFlutterClient(client!, 'wait_for_idle');
        return await _waitForIdle(args, fc);

      // === NEW: Smart Scroll ===
      case 'scroll_until_visible':
        if (client is BridgeDriver) {
          return await client.callMethod('scroll_until_visible', {
            'key': args['key'],
            'text': args['text'],
            'direction': args['direction'] ?? 'down',
            'max_scrolls': args['max_scrolls'] ?? 10
          });
        }
        final fc = _asFlutterClient(client!, 'scroll_until_visible');
        return await _scrollUntilVisible(args, fc);

      // === Batch Assertions ===
      default:
        return null;
    }
  }
}
