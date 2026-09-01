part of '../server.dart';

extension _NativeHandlers on FlutterMcpServer {
  /// Native platform interaction tools
  /// Returns null if the tool is not handled.
  Future<dynamic> _handleNativeTools(
      String name, Map<String, dynamic> args) async {
    if (name == 'native_screenshot') {
      final driver = await _getNativeDriver(args);
      if (driver == null) {
        return {
          "success": false,
          "error": {
            "code": "E501",
            "message": "No supported platform detected",
          },
          "suggestions": [
            "Ensure an iOS Simulator or Android emulator is running",
            "If using a physical device, native tools are not yet supported",
          ],
        };
      }
      final saveToFile = args['save_to_file'] ?? true;
      final result = await driver.screenshot(saveToFile: saveToFile);
      final json = result.toJson();
      // Attach scale_factor so callers can convert physical → logical pixels.
      // Flutter's tap(x,y) uses logical pixels; native_screenshot returns
      // physical (device) pixels.  logical = physical / scale_factor.
      if (json['success'] == true) {
        final meta = result.metadata;
        final pw = (meta?['width'] as num?)?.toDouble();
        final ph = (meta?['height'] as num?)?.toDouble();
        final lw = (meta?['logical_width'] as num?)?.toDouble();
        final lh = (meta?['logical_height'] as num?)?.toDouble();
        if (pw != null && lw != null && lw > 0) {
          final scale = double.parse((pw / lw).toStringAsFixed(2));
          json['scale_factor'] = scale;
          json['coordinate_hint'] = 'Physical: ${pw.toInt()}×${ph?.toInt()}px. '
              'Flutter tap() uses logical px — divide by $scale. '
              'Logical: ${lw.toInt()}×${lh?.toInt()}px.';
        } else if (pw != null && ph != null) {
          json['coordinate_hint'] =
              'Image is ${pw.toInt()}×${ph.toInt()} physical px. '
              'Flutter tap(x,y) uses logical px (divide by device scale, '
              'typically 2× or 3×). Use native_tap for physical-px coordinates.';
        }
      }
      return json;
    }

    if (name == 'native_tap') {
      final driver = await _getNativeDriver(args);
      if (driver == null) {
        return {
          "success": false,
          "error": {
            "code": "E501",
            "message": "No supported platform detected",
          },
        };
      }

      final toolCheck = await driver.checkToolAvailability();
      final missingTools =
          toolCheck.entries.where((e) => !e.value).map((e) => e.key).toList();
      if (missingTools.isNotEmpty) {
        return {
          "success": false,
          "error": {
            "code": "E502",
            "message": "Missing required tools: ${missingTools.join(', ')}",
          },
          "suggestions": driver.platform == NativePlatform.iosSimulator
              ? [
                  "Ensure Xcode command line tools are installed: xcode-select --install"
                ]
              : [
                  "Install Android platform tools: brew install android-platform-tools"
                ],
        };
      }

      final x = (args['x'] as num).toDouble();
      final y = (args['y'] as num).toDouble();
      final result = await driver.tap(x, y).timeout(
            const Duration(seconds: 15),
            onTimeout: () => NativeResult(
                success: false,
                message:
                    'native_tap timed out (15s) — check macOS Accessibility permissions'),
          );
      return result.toJson();
    }

    if (name == 'native_input_text') {
      final driver = await _getNativeDriver(args);
      if (driver == null) {
        return {
          "success": false,
          "error": {
            "code": "E501",
            "message": "No supported platform detected",
          },
        };
      }
      final text = args['text'] as String;
      final result = await driver.inputText(text).timeout(
            const Duration(seconds: 15),
            onTimeout: () => NativeResult(
                success: false,
                message:
                    'native_input_text timed out (15s) — check macOS Accessibility permissions'),
          );
      return result.toJson();
    }

    if (name == 'native_swipe') {
      final driver = await _getNativeDriver(args);
      if (driver == null) {
        return {
          "success": false,
          "error": {
            "code": "E501",
            "message": "No supported platform detected",
          },
        };
      }
      final startX = (args['start_x'] as num).toDouble();
      final startY = (args['start_y'] as num).toDouble();
      final endX = (args['end_x'] as num).toDouble();
      final endY = (args['end_y'] as num).toDouble();
      final duration = args['duration'] as int? ?? 300;
      final result = await driver
          .swipe(startX, startY, endX, endY, durationMs: duration)
          .timeout(
            const Duration(seconds: 15),
            onTimeout: () => NativeResult(
                success: false,
                message:
                    'native_swipe timed out (15s) — check macOS Accessibility permissions'),
          );
      return result.toJson();
    }

    if (name == 'native_snapshot') {
      final driver = await _getNativeDriver(args);
      if (driver == null) {
        return {"success": false, "error": "No supported platform detected"};
      }
      var tree = await driver.getAccessibilityTree().timeout(
            const Duration(seconds: 20),
            onTimeout: () => <Map<String, dynamic>>[],
          );

      // Fallback: if osascript AX tree failed, try bridge inspect
      if (tree.isEmpty && _client != null) {
        try {
          if (_client is BridgeDriver) {
            final bridgeResult =
                await (_client as BridgeDriver).callMethod('inspect', {});
            final elements = bridgeResult['elements'] as List<dynamic>? ?? [];
            if (elements.isNotEmpty) {
              // Convert bridge inspect format to AX tree format
              final converted = <Map<String, dynamic>>[];
              for (final e in elements) {
                final el = e as Map<String, dynamic>;
                converted.add(<String, dynamic>{
                  'role': el['type'] as String? ?? 'unknown',
                  'name': (el['text'] as String?) ??
                      (el['accessibilityLabel'] as String?) ??
                      '',
                  'value': '',
                  'depth': 0,
                });
              }
              tree = converted;
            }
          }
        } catch (_) {
          // Bridge fallback failed — continue to error
        }
      }

      if (tree.isEmpty) {
        return {
          "success": false,
          "error":
              "Could not read accessibility tree — check macOS Accessibility permissions for Terminal/IDE, "
                  "or connect via bridge SDK (scan_and_connect) for bridge-based inspection"
        };
      }

      // Build compact text snapshot (like CDP snapshot)
      final buf = StringBuffer();
      var interactiveCount = 0;
      for (final el in tree) {
        final role = el['role'] as String? ?? '';
        final name = el['name'] as String? ?? '';
        final value = el['value'] as String? ?? '';
        final depth = el['depth'] as int? ?? 0;
        final indent = '  ' * depth;

        if (role == 'text') {
          buf.writeln('$indent"$name"');
        } else if (role == 'button' ||
            role == 'link' ||
            role == 'textbox' ||
            role == 'checkbox' ||
            role == 'switch' ||
            role == 'slider' ||
            role == 'radio' ||
            role == 'tab') {
          interactiveCount++;
          final valStr = value.isNotEmpty ? ' value="$value"' : '';
          buf.writeln('$indent[$role] $name$valStr');
        } else if (name.isNotEmpty) {
          buf.writeln('$indent($role) $name');
        }
      }

      return {
        "snapshot": buf.toString(),
        "summary": "Found $interactiveCount interactive elements",
        "elementCount": tree.length,
        "interactiveCount": interactiveCount,
        "platform": "ios_simulator",
        "method": "macOS_accessibility_api",
        "elements": tree,
      };
    }

    if (name == 'native_find_elements') {
      final driver = await _getNativeDriver(args);
      if (driver == null) {
        return {"success": false, "error": "No supported platform detected"};
      }
      final elements = await driver.findElements(
        role: args['role'] as String?,
        name: args['name'] as String?,
        text: args['text'] as String?,
      );
      return {
        "success": true,
        "count": elements.length,
        "elements": elements.take(50).toList(),
      };
    }

    if (name == 'native_get_text') {
      final driver = await _getNativeDriver(args);
      if (driver == null) {
        return {"success": false, "error": "No supported platform detected"};
      }
      final text = await driver.getVisibleText();
      return {"success": true, "text": text};
    }

    if (name == 'native_tap_element') {
      final driver = await _getNativeDriver(args);
      if (driver is! IosSimulatorDriver) {
        return {
          "success": false,
          "error": "native_tap_element requires iOS Simulator"
        };
      }
      final elName = args['name'] as String? ?? '';
      final role = args['role'] as String?;
      final result = await driver.tapByName(elName, role: role).timeout(
            const Duration(seconds: 15),
            onTimeout: () => NativeResult(
                success: false, message: 'native_tap_element timed out (15s)'),
          );
      return result.toJson();
    }

    if (name == 'native_element_at') {
      final driver = await _getNativeDriver(args);
      if (driver == null) {
        return {"success": false, "error": "No supported platform detected"};
      }
      final x = (args['x'] as num).toDouble();
      final y = (args['y'] as num).toDouble();
      final el = await driver.getElementAt(x, y);
      return {"success": el.isNotEmpty, "element": el};
    }

    if (name == 'native_long_press') {
      final driver = await _getNativeDriver(args);
      if (driver == null) {
        return {
          "success": false,
          "error": {
            "code": "E501",
            "message": "No supported platform detected",
          },
        };
      }
      final x = (args['x'] as num).toDouble();
      final y = (args['y'] as num).toDouble();
      final duration = args['duration'] as int? ?? 1000;
      final result = await driver.longPress(x, y, durationMs: duration).timeout(
            Duration(milliseconds: duration + 15000),
            onTimeout: () => NativeResult(
                success: false, message: 'native_long_press timed out'),
          );
      return result.toJson();
    }

    if (name == 'native_gesture') {
      final driver = await _getNativeDriver(args);
      if (driver == null) {
        return {
          "success": false,
          "error": {
            "code": "E501",
            "message": "No supported platform detected",
          },
        };
      }
      final gesture =
          (args['gesture'] ?? args['type'] ?? args['name']) as String;
      final result = await driver.gesture(gesture).timeout(
            const Duration(seconds: 15),
            onTimeout: () => NativeResult(
                success: false, message: 'native_gesture timed out'),
          );
      return result.toJson();
    }

    if (name == 'native_press_key') {
      final driver = await _getNativeDriver(args);
      if (driver == null) {
        return {
          "success": false,
          "error": {
            "code": "E501",
            "message": "No supported platform detected",
          },
        };
      }
      final key = args['key'] as String;
      final result = await driver.pressKey(key).timeout(
            const Duration(seconds: 10),
            onTimeout: () => NativeResult(
                success: false, message: 'native_press_key timed out'),
          );
      return result.toJson();
    }

    if (name == 'native_key_combo') {
      final driver = await _getNativeDriver(args);
      if (driver == null) {
        return {
          "success": false,
          "error": {
            "code": "E501",
            "message": "No supported platform detected",
          },
        };
      }
      // Accept both String ("shift+a") and List (["shift", "a"])
      final rawKeys = args['keys'];
      final keys = rawKeys is List ? rawKeys.join('+') : rawKeys as String;
      final result = await driver.keyCombo(keys).timeout(
            const Duration(seconds: 10),
            onTimeout: () => NativeResult(
                success: false, message: 'native_key_combo timed out'),
          );
      return result.toJson();
    }

    if (name == 'native_button') {
      final driver = await _getNativeDriver(args);
      if (driver == null) {
        return {
          "success": false,
          "error": {
            "code": "E501",
            "message": "No supported platform detected",
          },
        };
      }
      final button = args['button'] as String;
      final result = await driver.hardwareButton(button).timeout(
            const Duration(seconds: 10),
            onTimeout: () => NativeResult(
                success: false, message: 'native_button timed out'),
          );
      return result.toJson();
    }

    if (name == 'native_video_start') {
      final driver = await _getNativeDriver(args);
      if (driver is! IosSimulatorDriver) {
        return {
          "success": false,
          "error": "native_video_start requires iOS Simulator"
        };
      }
      final path = args['path'] as String?;
      final result = await driver.startVideoRecording(path: path).timeout(
            const Duration(seconds: 10),
            onTimeout: () => NativeResult(
                success: false, message: 'native_video_start timed out'),
          );
      return result.toJson();
    }

    if (name == 'native_video_stop') {
      final driver = await _getNativeDriver(args);
      if (driver is! IosSimulatorDriver) {
        return {
          "success": false,
          "error": "native_video_stop requires iOS Simulator"
        };
      }
      final result = await driver.stopVideoRecording().timeout(
            const Duration(seconds: 15),
            onTimeout: () => NativeResult(
                success: false, message: 'native_video_stop timed out'),
          );
      return result.toJson();
    }

    if (name == 'native_capture_frames') {
      final driver = await _getNativeDriver(args);
      if (driver is! IosSimulatorDriver) {
        return {
          "success": false,
          "error": "native_capture_frames requires iOS Simulator"
        };
      }
      final fps = args['fps'] as int? ?? 5;
      final durationMs = args['duration_ms'] as int? ?? 3000;
      final quality = args['quality'] as int? ?? 80;
      final result = await driver
          .captureFrames(fps: fps, durationMs: durationMs, quality: quality)
          .timeout(
            Duration(milliseconds: durationMs + 10000),
            onTimeout: () => NativeResult(
                success: false, message: 'native_capture_frames timed out'),
          );
      return result.toJson();
    }

    if (name == 'native_list_simulators') {
      final platform = args['platform'] as String? ?? 'all';
      final devices = await NativeDriver.listDevices(platform: platform);
      return {"success": true, ...devices};
    }

    if (name == 'idb_describe') {
      final driver = await NativeDriver.create(null);
      if (driver is! IosSimulatorDriver) {
        return {
          "success": false,
          "error":
              "No booted iOS Simulator found. idb requires a running simulator.",
        };
      }
      final info = await driver.describe();
      return {"success": info['idb_available'] == true, ...info};
    }

    // Auth tools (system commands, no bridge connection required)

    return null; // Not handled by this group
  }
}
