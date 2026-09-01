part of '../server.dart';

extension _DevToolHandlers on FlutterMcpServer {
  /// Developer tools (hot reload, pub search, indicators)
  /// Returns null if the tool is not handled.
  Future<dynamic> _handleDevTools(
      String name, Map<String, dynamic> args) async {
    if (name == 'pub_search') {
      final query = args['query'];
      final url = Uri.parse('https://pub.dev/api/search?q=$query');
      final response = await http.get(url);
      if (response.statusCode != 200) throw Exception("Pub search failed");
      final json = jsonDecode(response.body);
      return json['packages'];
    }

    if (name == 'hot_reload') {
      final client = _getClient(args);
      _requireConnection(client);
      if (client is FlutterSkillClient) return await client.hotReload();
      await client!.hotReload();
      return "Hot reload triggered";
    }

    if (name == 'hot_restart') {
      final client = _getClient(args);
      _requireConnection(client);
      final fc = _asFlutterClient(client!, 'hot_restart');
      return await fc.hotRestart();
    }

    if (name == 'enable_test_indicators') {
      final client = _getClient(args);
      _requireConnection(client);
      if (client is CdpDriver) {
        return {"success": true, "enabled": false, "message": "No-op for CDP"};
      }
      if (client is BridgeDriver) {
        final enabled = args['enabled'] ?? true;
        final style = args['style'] ?? 'standard';
        return await client.callMethod(
            'enable_test_indicators', {'enabled': enabled, 'style': style});
      }
      final fc = _asFlutterClient(client!, 'enable_test_indicators');
      final enabled = args['enabled'] ?? true;
      final style = args['style'] ?? 'standard';

      if (enabled) {
        await fc.enableTestIndicators(style: style);
        return {
          "success": true,
          "enabled": true,
          "style": style,
          "message": "Test indicators enabled with $style style"
        };
      } else {
        await fc.disableTestIndicators();
        return {
          "success": true,
          "enabled": false,
          "message": "Test indicators disabled"
        };
      }
    }

    if (name == 'get_indicator_status') {
      final client = _getClient(args);
      _requireConnection(client);
      if (client is CdpDriver) {
        return {"enabled": false, "message": "No-op for CDP"};
      }
      if (client is BridgeDriver) {
        return await client.callMethod('get_indicator_status');
      }
      final fc = _asFlutterClient(client!, 'get_indicator_status');
      return await fc.getIndicatorStatus();
    }

    if (name == 'reset_app') {
      final client = _getClient(args);
      final clearStorage = args['clear_storage'] ?? true;
      final clearCookies = args['clear_cookies'] ?? true;

      // CDP: clear browser state and reload
      if (client is CdpDriver) {
        final actions = <String>[];
        if (clearStorage) {
          await client.call('Runtime.evaluate', {
            'expression': 'localStorage.clear(); sessionStorage.clear();',
            'returnByValue': true,
          });
          actions.add('storage cleared');
        }
        if (clearCookies) {
          await client.call('Network.clearBrowserCookies');
          actions.add('cookies cleared');
        }
        // Reload page
        await client.call('Page.reload', {'ignoreCache': true});
        await Future.delayed(const Duration(seconds: 2));
        actions.add('page reloaded');
        return {
          'success': true,
          'platform': 'cdp',
          'actions': actions,
        };
      }

      // Bridge: send reset command
      if (client is BridgeDriver) {
        try {
          final result = await client.callMethod('reset_app', {
            'clear_storage': clearStorage,
          });
          return {'success': true, 'platform': 'bridge', 'result': result};
        } catch (_) {
          // Fallback: try go_back to home, then re-initialize
          try {
            await client.callMethod('go_back');
          } catch (_) {}
          try {
            await client.callMethod('initialize', {'client_name': 'reset'});
          } catch (_) {}
          return {
            'success': true,
            'platform': 'bridge',
            'fallback': 'go_back+reinitialize',
            'note':
                'Full reset not supported on this platform; navigated back and re-initialized',
          };
        }
      }

      // Flutter: hot restart
      if (client != null) {
        try {
          final fc = _asFlutterClient(client, 'reset_app');
          await fc.hotRestart();
          return {
            'success': true,
            'platform': 'flutter',
            'action': 'hot_restart'
          };
        } catch (e) {
          return {'success': false, 'error': e.toString()};
        }
      }

      // Android: adb clear
      try {
        // Try to find package name from active session
        final adbResult = await Process.run('adb', [
          'shell',
          'dumpsys',
          'activity',
          'activities',
        ]);
        final output = adbResult.stdout as String;
        final match =
            RegExp(r'mResumedActivity.*?(\w+\.\w+[\.\w]*)/').firstMatch(output);
        if (match != null) {
          final pkg = match.group(1)!;
          await Process.run('adb', ['shell', 'pm', 'clear', pkg]);
          return {
            'success': true,
            'platform': 'android',
            'package': pkg,
            'action': 'pm clear'
          };
        }
      } catch (_) {}

      return {'success': false, 'error': 'No connected app to reset'};
    }

    // Native platform interaction tools (no VM Service connection required)

    return null; // Not handled by this group
  }
}
