part of '../server.dart';

extension _BfInteraction on FlutterMcpServer {
  Future<dynamic> _handleInteractionTool(
      String name, Map<String, dynamic> args, AppDriver? client) async {
    switch (name) {
      case 'tap':
        // Support three methods: key, text, or coordinates
        final x = args['x'] as num?;
        final y = args['y'] as num?;

        // Method 3: Tap by coordinates
        if (x != null && y != null) {
          if (client is BridgeDriver) {
            await client
                .callMethod('tap_at', {'x': x.toDouble(), 'y': y.toDouble()});
            return {
              "success": true,
              "method": "coordinates",
              "message": "Tapped at ($x, $y)",
              "position": {"x": x, "y": y}
            };
          }
          final fc = _asFlutterClient(client!, 'tap (coordinates)');
          final tapped = await fc.tapAt(x.toDouble(), y.toDouble());
          return {
            "success": true,
            "method": "coordinates",
            "message": "Tapped at ($x, $y)",
            "position": {"x": x, "y": y},
            if (tapped['warning'] != null) "warning": tapped['warning'],
          };
        }

        // Method 1 & 2: Tap by key, text, or semantic ref
        final result = await client!.tap(
          key: args['key'],
          text: args['text'],
          ref: args['ref'],
        );
        if (result['success'] != true) {
          // Return full error details including suggestions
          return {
            "success": false,
            "error": result['error'] ?? {"message": "Element not found"},
            "target":
                result['target'] ?? {"key": args['key'], "text": args['text']},
            if (result['suggestions'] != null)
              "suggestions": result['suggestions'],
          };
        }
        return {
          "success": true,
          "method": args['key'] != null ? "key" : "text",
          "message": "Tapped",
          if (result['position'] != null) "position": result['position'],
          if (result['warning'] != null) "warning": result['warning'],
        };

      case 'fill':
      case 'enter_text':
        final etKey = args['key'] as String?;
        final etText = (args['text'] ?? args['value'] ?? '') as String;
        // If no key/ref provided, try entering into the currently focused field.
        // The Flutter binding handles null key by targeting the focused TextField.
        final result = await client!.enterText(
          etKey,
          etText,
          ref: args['ref'],
        );
        if (result['success'] != true) {
          final err = result['error'];
          final errMsg = err is Map ? err['message'] : err?.toString();
          final noKey = etKey == null && args['ref'] == null;
          return {
            "success": false,
            "error": result['error'] ?? {"message": "TextField not found"},
            "target": result['target'] ?? {"key": etKey},
            if (result['suggestions'] != null)
              "suggestions": result['suggestions'],
            // Actionable hint when called without a key and field not found
            if (noKey && (errMsg?.contains('null') ?? false))
              "hint":
                  "No focused TextField detected. Call inspect_interactive() to list available TextFields, then pass 'key' or tap the field first.",
          };
        }
        return {"success": true, "message": "Text entered"};

      case 'scroll_to':
        if (client is BridgeDriver) {
          await client.scroll(
              direction: args['direction'] ?? 'down',
              distance: args['distance'] ?? 300);
          return {"success": true, "message": "Scrolled"};
        }
        final fc = _asFlutterClient(client!, 'scroll_to');
        final result =
            await fc.scrollTo(key: args['key'], text: args['text']).timeout(
                  const Duration(seconds: 8),
                  onTimeout: () => {
                    'success': false,
                    'message':
                        'scroll_to timed out — element may be unreachable. '
                            'Use swipe() to scroll manually instead.',
                  },
                );
        if (result['success'] != true) {
          return {
            "success": false,
            "error": result['message'] ?? 'Element not found or unreachable',
            "suggestion": "Use swipe(direction: 'up') to scroll manually, "
                "then retry scroll_to once the element is closer to the viewport.",
          };
        }
        return {"success": true, "message": "Scrolled"};

      // Advanced Actions
      case 'long_press':
        if (client is BridgeDriver) {
          final success =
              await client.longPress(key: args['key'], text: args['text']);
          return success ? "Long pressed" : "Long press failed";
        }
        final fc = _asFlutterClient(client!, 'long_press');
        final duration = args['duration'] ?? 500;
        final success = await fc.longPress(
            key: args['key'], text: args['text'], duration: duration);
        return success ? "Long pressed" : "Long press failed";
      case 'double_tap':
        if (client is BridgeDriver) {
          final success =
              await client.doubleTap(key: args['key'], text: args['text']);
          return success ? "Double tapped" : "Double tap failed";
        }
        final fc = _asFlutterClient(client!, 'double_tap');
        final success =
            await fc.doubleTap(key: args['key'], text: args['text']);
        return success ? "Double tapped" : "Double tap failed";
      case 'swipe':
        final distance = (args['distance'] ?? 300).toDouble();
        if (client is FlutterSkillClient) {
          final swiped = await client.swipeWithDetails(
              direction: args['direction'],
              distance: distance,
              key: args['key']);
          return {
            "success": swiped['success'] == true,
            "message": swiped['success'] == true
                ? "Swiped ${args['direction']}"
                : "Swipe failed",
            if (swiped['warning'] != null) "warning": swiped['warning'],
          };
        }
        final success = await client!.swipe(
            direction: args['direction'], distance: distance, key: args['key']);
        return success ? "Swiped ${args['direction']}" : "Swipe failed";
      case 'drag':
        if (client is BridgeDriver) {
          // Support both key-based and coordinate-based drag
          if (args['start_x'] != null) {
            final result = await client.callMethod('drag', {
              'start_x': (args['start_x'] as num).toDouble(),
              'start_y': (args['start_y'] as num).toDouble(),
              'end_x': (args['end_x'] as num).toDouble(),
              'end_y': (args['end_y'] as num).toDouble(),
            });
            return result;
          }
          final result = await client.callMethod(
              'drag', {'from_key': args['from_key'], 'to_key': args['to_key']});
          return result['success'] == true ? "Dragged" : "Drag failed";
        }
        final fc = _asFlutterClient(client!, 'drag');
        // Clients may send numbers as strings; accept both.
        double? num_(Object? v) =>
            v is num ? v.toDouble() : double.tryParse(v?.toString() ?? '');
        final holdMs = num_(args['hold_ms'])?.toInt() ?? 0;
        // Coordinate-based drag shares the swipe engine (with hold)
        if (num_(args['start_x']) != null) {
          final result = await fc.swipeCoordinates(
            num_(args['start_x'])!,
            num_(args['start_y']) ?? 0,
            num_(args['end_x']) ?? 0,
            num_(args['end_y']) ?? 0,
            duration: num_(args['duration_ms'])?.toInt() ?? 400,
            holdMs: holdMs,
          );
          return result;
        }
        final dragged = await fc.dragWithDetails(
            fromKey: args['from_key'] as String? ?? '',
            toKey: args['to_key'] as String? ?? '',
            holdMs: holdMs);
        return {
          "success": dragged['success'] == true,
          "message": dragged['success'] == true ? "Dragged" : "Drag failed",
          if (dragged['warning'] != null) "warning": dragged['warning'],
        };

      // State & Validation
      case 'get_text_value':
        if (client is BridgeDriver) {
          final text = await client.getText(key: args['key'] as String?);
          return {"success": true, "text": text};
        }
        final fc = _asFlutterClient(client!, 'get_text_value');
        return await fc.getTextValue(args['key'] as String?);
      case 'get_checkbox_state':
        if (client is BridgeDriver) {
          return await client
              .callMethod('get_checkbox_state', {'key': args['key']});
        }
        final fc = _asFlutterClient(client!, 'get_checkbox_state');
        final checked = await fc.getCheckboxState(args['key']);
        return checked == null
            ? {"success": false, "error": "No Checkbox/Switch with that key"}
            : {"success": true, "checked": checked};
      case 'set_checkbox':
        if (client is BridgeDriver) {
          return await client.callMethod(
              'set_checkbox', {'key': args['key'], 'checked': args['checked']});
        }
        return await _asFlutterClient(client!, 'set_checkbox')
            .setCheckbox(args['key'] as String, args['checked'] == true);
      case 'type_text':
        if (client is BridgeDriver) {
          return await client.callMethod('type_text', {'text': args['text']});
        }
        return await _asFlutterClient(client!, 'type_text')
            .typeText(args['text'] as String? ?? '');
      case 'focus':
        if (client is BridgeDriver) {
          return await client.callMethod('focus', {'key': args['key']});
        }
        return await _asFlutterClient(client!, 'focus')
            .focus(args['key'] as String? ?? '');
      case 'blur':
        if (client is BridgeDriver) {
          return await client.callMethod('blur', {'key': args['key']});
        }
        return await _asFlutterClient(client!, 'blur')
            .blur(key: args['key'] as String?);
      case 'hover':
        if (client is BridgeDriver) {
          return await client.callMethod('hover',
              {'key': args['key'], 'text': args['text'], 'ref': args['ref']});
        }
        return await _asFlutterClient(client!, 'hover')
            .hover(key: args['key'] as String?, text: args['text'] as String?);
      case 'get_slider_value':
        if (client is BridgeDriver) {
          return await client
              .callMethod('get_slider_value', {'key': args['key']});
        }
        final fc = _asFlutterClient(client!, 'get_slider_value');
        return await fc.getSliderValue(args['key']);
      case 'wait_for_element':
        if (client is BridgeDriver) {
          final timeout = args['timeout'] ?? 5000;
          final found = await client.waitForElement(
              key: args['key'], text: args['text'], timeout: timeout);
          return {"found": found};
        }
        final fc = _asFlutterClient(client!, 'wait_for_element');
        final timeout = args['timeout'] ?? 5000;
        final found = await fc.waitForElement(
            key: args['key'], text: args['text'], timeout: timeout);
        return {"found": found};
      case 'wait_for_gone':
        if (client is BridgeDriver) {
          final result = await client.callMethod('wait_for_gone', {
            'key': args['key'],
            'text': args['text'],
            'timeout': args['timeout'] ?? 5000
          });
          return {"gone": result['gone'] ?? true};
        }
        final fc = _asFlutterClient(client!, 'wait_for_gone');
        final timeout = args['timeout'] ?? 5000;
        final gone = await fc.waitForGone(
            key: args['key'], text: args['text'], timeout: timeout);
        return {"gone": gone};

      case 'press_key':
        final key = args['key'] as String? ?? '';
        if (key.isEmpty) {
          return {"success": false, "error": "Missing 'key' argument"};
        }
        if (client is BridgeDriver) {
          await client.callMethod('press_key', {'key': key});
          return {"success": true, "message": "Key pressed: $key"};
        }
        // Flutter VM Service — use the registered pressKey extension
        if (client is FlutterSkillClient) {
          final result = await client.pressKey(key);
          if (result['success'] == true) {
            return {"success": true, "message": "Key pressed: $key"};
          }
          // FlutterSkillClient failed — fall through to NativeDriver below
        }
        // NativeDriver fallback: works on iOS Simulator and Android Emulator
        // even when no VM Service extension is registered.
        final nativeDriver = await _getNativeDriver(args);
        if (nativeDriver != null) {
          final nResult = await nativeDriver.pressKey(key);
          return nResult.success
              ? {"success": true, "message": "Key pressed via native: $key"}
              : {
                  "success": false,
                  "error": nResult.message ?? "Native pressKey failed",
                  "hint":
                      "Try native_press_key tool, or use a UI button instead of keyboard.",
                };
        }
        return {
          "success": false,
          "error":
              "press_key not supported in this mode. Connect via CDP, a bridge SDK, or ensure a simulator/emulator is running for native key injection.",
          "hint":
              "For iOS: use native_press_key. For web: use CDP mode (connect_cdp).",
        };

      case 'scroll':
        final direction = args['direction'] as String? ?? 'down';
        final amount = (args['amount'] as num?)?.toDouble() ?? 300;
        if (client is BridgeDriver) {
          await client.callMethod('scroll', {
            'direction': direction,
            'amount': amount,
          });
          return {"success": true, "message": "Scrolled $direction by $amount"};
        }
        // Flutter: use scrollTo with key/text if provided
        if (args['key'] != null || args['text'] != null) {
          final fc = _asFlutterClient(client!, 'scroll');
          await fc.scrollTo(
              key: args['key'] as String?, text: args['text'] as String?);
          return {"success": true, "message": "Scrolled to element"};
        }
        return {
          "success": false,
          "error": "scroll on Flutter requires 'key' or 'text' argument"
        };

      case 'find_element':
        final text = args['text'] as String?;
        final key = args['key'] as String?;
        if (text == null && key == null) {
          return {"success": false, "error": "Provide 'text' or 'key'"};
        }
        if (client is BridgeDriver) {
          final result = await client.callMethod('find_element', {
            if (text != null) 'text': text,
            if (key != null) 'key': key,
          });
          return result;
        }
        final fc2 = _asFlutterClient(client!, 'find_element');
        final elements = await fc2.findByType(text ?? key ?? '');
        return {"found": elements.isNotEmpty, "count": elements.length};

      case 'get_text':
        if (client is BridgeDriver) {
          final result = await client.callMethod('get_text', {
            if (args['ref'] != null) 'ref': args['ref'],
            if (args['key'] != null) 'key': args['key'],
          });
          return result;
        }
        final fc3 = _asFlutterClient(client!, 'get_text');
        final textContent = await fc3.getTextContent();
        return {"text": textContent};

      // Screenshot
      default:
        return null;
    }
  }
}
