part of '../server.dart';

extension _MultiDeviceHandlers on FlutterMcpServer {
  /// Multi-device sync testing tools.
  /// Returns null if the tool is not handled by this group.
  Future<dynamic> _handleMultiDeviceTools(
      String name, Map<String, dynamic> args) async {
    switch (name) {
      case 'multi_connect':
        return _handleMultiConnect(args);
      case 'multi_action':
        return _handleMultiAction(args);
      case 'multi_compare':
        return _handleMultiCompare(args);
      case 'multi_disconnect':
        return _handleMultiDisconnect(args);
      default:
        return null;
    }
  }

  /// Internal storage for multi-device connections.
  /// Uses the server's existing session infrastructure where possible.
  static final Map<String, AppDriver> _multiDevices = {};

  Future<Map<String, dynamic>> _handleMultiConnect(
      Map<String, dynamic> args) async {
    final devices = args['devices'] as List<dynamic>?;
    if (devices == null || devices.isEmpty) {
      return {'success': false, 'error': 'devices array is required'};
    }

    final connected = <String>[];
    final errors = <Map<String, dynamic>>[];

    for (final dev in devices) {
      final d = dev as Map<String, dynamic>;
      final name = d['name'] as String? ?? 'device_${connected.length}';
      final type = d['type'] as String? ?? 'cdp';
      final url = d['url'] as String? ?? 'about:blank';
      final port = (d['port'] as num?)?.toInt() ?? 9222;

      try {
        AppDriver driver;
        switch (type) {
          case 'cdp':
            final cdp = CdpDriver(
              url: url,
              port: port,
              launchChrome: false,
              headless: false,
            );
            await cdp.connect();
            driver = cdp;
            break;
          case 'bridge':
            final wsUri = 'ws://localhost:$port/ws';
            final info = BridgeServiceInfo(
              framework: 'web',
              appName: name,
              platform: 'web',
              capabilities: <String>{},
              sdkVersion: '0.0.0',
              port: port,
              wsUri: wsUri,
            );
            final bridge = BridgeDriver(wsUri, info);
            await bridge.connect();
            driver = bridge;
            break;
          default:
            errors.add({
              'device': name,
              'error': 'Unsupported device type: $type. Supported: cdp, bridge',
            });
            continue;
        }
        _multiDevices[name] = driver;
        connected.add(name);
      } catch (e) {
        errors.add({'device': name, 'error': e.toString()});
      }
    }

    return {
      'success': errors.isEmpty,
      'connected': connected,
      'errors': errors,
      'total_devices': _multiDevices.length,
    };
  }

  Future<Map<String, dynamic>> _handleMultiAction(
      Map<String, dynamic> args) async {
    final action = args['action'] as String?;
    final arguments = (args['arguments'] as Map<String, dynamic>?) ?? {};
    final deviceNames = (args['devices'] as List<dynamic>?)?.cast<String>();

    if (action == null) {
      return {'success': false, 'error': 'action is required'};
    }

    if (_multiDevices.isEmpty) {
      return {
        'success': false,
        'error': 'No multi-device connections. Use multi_connect first.',
      };
    }

    final targets = deviceNames != null
        ? {
            for (final n in deviceNames)
              if (_multiDevices.containsKey(n)) n: _multiDevices[n]!
          }
        : Map.of(_multiDevices);

    if (targets.isEmpty) {
      return {'success': false, 'error': 'No matching devices found'};
    }

    final futures = targets.entries.map((entry) async {
      final deviceName = entry.key;
      final driver = entry.value;
      try {
        final result = driver is CdpDriver
            ? await _executeCdpTool(action, arguments, driver)
            : await _handleBridgeFlutterTool(action, arguments, driver);
        return {'device': deviceName, 'success': true, 'result': result};
      } catch (e) {
        return {'device': deviceName, 'success': false, 'error': e.toString()};
      }
    });

    final results = await Future.wait(futures);
    final allSuccess = results.every((r) => r['success'] == true);

    return {
      'success': allSuccess,
      'results': results,
      'device_count': targets.length,
    };
  }

  Future<Map<String, dynamic>> _handleMultiCompare(
      Map<String, dynamic> args) async {
    final type = args['type'] as String? ?? 'snapshot';
    final saveDir = args['save_dir'] as String?;

    if (_multiDevices.isEmpty) {
      return {
        'success': false,
        'error': 'No multi-device connections. Use multi_connect first.',
      };
    }

    final futures = _multiDevices.entries.map((entry) async {
      final deviceName = entry.key;
      final driver = entry.value;
      try {
        if (type == 'screenshot') {
          final image = await driver.takeScreenshot();
          if (saveDir != null && image != null) {
            final file = File('$saveDir/${deviceName}_screenshot.png');
            await file.parent.create(recursive: true);
            await file.writeAsBytes(base64Decode(image));
          }
          return {
            'device': deviceName,
            'type': 'screenshot',
            'has_image': image != null,
            'saved': saveDir != null,
          };
        } else {
          // Snapshot via CDP accessibility tree or bridge tree
          Map<String, dynamic> snapshot;
          if (driver is CdpDriver) {
            snapshot = await driver.accessibilityAudit();
          } else {
            snapshot = {
              'tree': (await driver.takeScreenshot()) ?? 'no snapshot'
            };
          }
          if (saveDir != null) {
            final file = File('$saveDir/${deviceName}_snapshot.json');
            await file.parent.create(recursive: true);
            await file.writeAsString(jsonEncode(snapshot));
          }
          return {
            'device': deviceName,
            'type': 'snapshot',
            'snapshot': snapshot,
            'saved': saveDir != null,
          };
        }
      } catch (e) {
        return {'device': deviceName, 'error': e.toString()};
      }
    });

    final results = await Future.wait(futures);

    // Simple comparison: check if all snapshots/screenshots are equivalent
    final deviceResults = results.toList();
    final differences = <String>[];

    if (type == 'snapshot' && deviceResults.length > 1) {
      final first = deviceResults.first;
      for (var i = 1; i < deviceResults.length; i++) {
        final other = deviceResults[i];
        if (first['error'] != null || other['error'] != null) continue;
        final firstJson = jsonEncode(first['snapshot']);
        final otherJson = jsonEncode(other['snapshot']);
        if (firstJson != otherJson) {
          differences.add('${first['device']} differs from ${other['device']}');
        }
      }
    }

    return {
      'success': true,
      'devices': deviceResults,
      'differences': differences,
      'all_match': differences.isEmpty,
    };
  }

  Future<Map<String, dynamic>> _handleMultiDisconnect(
      Map<String, dynamic> args) async {
    final disconnected = <String>[];
    final errors = <Map<String, dynamic>>[];

    for (final entry in _multiDevices.entries) {
      try {
        await entry.value.disconnect();
        disconnected.add(entry.key);
      } catch (e) {
        errors.add({'device': entry.key, 'error': e.toString()});
        disconnected.add(entry.key); // Still remove from map
      }
    }
    _multiDevices.clear();

    return {
      'success': errors.isEmpty,
      'disconnected': disconnected,
      'errors': errors,
    };
  }
}
