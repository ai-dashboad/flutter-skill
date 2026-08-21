import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'flutter_skill_semantic_refs.dart';

// Conditional web import for JS interop
import 'flutter_skill_web_stub.dart'
    if (dart.library.js_interop) 'flutter_skill_web_interop.dart'
    as web_interop;

// ==================== ERROR CODES ====================

class ErrorCode {
  // Element errors
  static const String elementNotFound = 'E001';
  static const String elementNotVisible = 'E002';
  static const String elementNotEnabled = 'E003';
  static const String multipleElements = 'E004';

  // Action errors
  static const String tapFailed = 'E101';
  static const String swipeFailed = 'E102';
  static const String inputFailed = 'E103';

  // Connection errors
  static const String appDisconnected = 'E201';
  static const String vmServiceError = 'E202';

  // Timeout errors
  static const String operationTimeout = 'E301';
  static const String elementWaitTimeout = 'E302';
}

/// The Binding that enables Flutter Skill automation.
class FlutterSkillBinding {
  static void ensureInitialized({bool autoEnableIndicators = true}) {
    if (_registered) return;
    _registered = true;
    _registerExtensions();

    // On web, expose Dart-side element lookup to JavaScript
    if (kIsWeb) {
      web_interop.registerWebBridge(_handleWebBridgeCall);
    }

    // Auto-enable test indicators after a short delay
    if (autoEnableIndicators) {
      Future.delayed(const Duration(milliseconds: 500), () {
        try {
          _indicatorsEnabled = true;
          _indicatorOverlay = TestIndicatorOverlay();
          _indicatorOverlay!.enable();
          _indicatorOverlay!.setStyle(IndicatorStyle.detailed);
          print('🎭 Test Indicators Auto-Enabled (detailed mode)');
        } catch (e) {
          print('⚠️ Failed to auto-enable indicators: $e');
        }
      });
    }

    print('Flutter Skill Binding Initialized 🚀');
  }

  static bool _registered = false;
  static final List<String> _logs = [];
  static final List<Map<String, dynamic>> _errors = [];
  static final List<Map<String, dynamic>> _httpRequests = [];
  static int _pointerCounter = 1;

  // Element cache for semantic ref system
  static Map<String, Map<String, dynamic>>? _lastInspectResult;

  // Test indicators
  static TestIndicatorOverlay? _indicatorOverlay;
  static bool _indicatorsEnabled = false;
  static Offset?
      _lastCharacterPosition; // Track character position for walking effect

  /// Handle a bridge call from the web JS bridge.
  /// Returns JSON string result.
  static String _handleWebBridgeCall(String method, String paramsJson) {
    try {
      final params = jsonDecode(paramsJson) as Map<String, dynamic>;
      switch (method) {
        case 'find_element':
          final key = params['key'] as String?;
          final text = params['text'] as String?;
          final element = _findElement(key: key, text: text);
          if (element == null) return jsonEncode({'found': false});
          final renderObj = element.renderObject;
          if (renderObj is RenderBox) {
            final offset = renderObj.localToGlobal(Offset.zero);
            final size = renderObj.size;
            return jsonEncode({
              'found': true,
              'element': {
                'type': element.widget.runtimeType.toString(),
                'key': key,
                'text': _extractTextFrom(element),
                'bounds': {
                  'x': offset.dx.round(),
                  'y': offset.dy.round(),
                  'width': size.width.round(),
                  'height': size.height.round(),
                },
              },
            });
          }
          return jsonEncode({
            'found': true,
            'element': {
              'type': element.widget.runtimeType.toString(),
              'key': key
            }
          });

        case 'get_text':
          final key = params['key'] as String?;
          final text = params['text'] as String?;
          final element = _findElement(key: key, text: text);
          if (element == null) return jsonEncode({'text': null});
          // For text fields, get the current value
          if (key != null) {
            final value = _getTextFieldValue(key);
            if (value != null) return jsonEncode({'text': value});
          }
          final extracted = _extractTextFrom(element);
          return jsonEncode({'text': extracted});

        case 'tap':
          final key = params['key'] as String?;
          final text = params['text'] as String?;
          final element = _findElement(key: key, text: text);
          if (element == null)
            return jsonEncode(
                {'success': false, 'message': 'Element not found'});
          final renderObj = element.renderObject;
          if (renderObj is RenderBox) {
            final center =
                renderObj.localToGlobal(renderObj.size.center(Offset.zero));
            // Schedule the tap
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _performTapAt(center.dx, center.dy);
            });
            return jsonEncode({'success': true, 'message': 'Tap scheduled'});
          }
          return jsonEncode({'success': false, 'message': 'No render object'});

        case 'enter_text':
          final key = params['key'] as String?;
          final textVal = params['text'] as String? ?? '';
          final element = key != null ? _findElementByKey(key) : null;
          if (element == null)
            return jsonEncode(
                {'success': false, 'message': 'Element not found'});
          final renderObj = element.renderObject;
          if (renderObj is RenderBox) {
            final center =
                renderObj.localToGlobal(renderObj.size.center(Offset.zero));
            // Tap to focus, then enter text
            WidgetsBinding.instance.addPostFrameCallback((_) async {
              await _performTapAt(center.dx, center.dy);
              await Future.delayed(const Duration(milliseconds: 100));
              // Use test text input to set the value
              final controller = _findTextEditingController(element);
              if (controller != null) {
                controller.text = textVal;
              }
            });
            return jsonEncode(
                {'success': true, 'message': 'Text entry scheduled'});
          }
          return jsonEncode({'success': false, 'message': 'No render object'});

        case 'wait_for_element':
          final key = params['key'] as String?;
          final text = params['text'] as String?;
          final element = _findElement(key: key, text: text);
          return jsonEncode({'found': element != null});

        default:
          return jsonEncode({'error': 'Unknown web bridge method: $method'});
      }
    } catch (e) {
      return jsonEncode({'error': e.toString()});
    }
  }

  static TextEditingController? _findTextEditingController(Element element) {
    TextEditingController? controller;
    void visit(Element el) {
      if (controller != null) return;
      final widget = el.widget;
      if (widget is EditableText) {
        controller = widget.controller;
        return;
      }
      el.visitChildren(visit);
    }

    visit(element);
    return controller;
  }

  static void _registerExtensions() {
    // ==================== EXISTING EXTENSIONS ====================

    // 1. Interactive Elements
    developer.registerExtension('ext.flutter.flutter_skill.interactive',
        (method, parameters) async {
      try {
        final elements = _findInteractiveElements();
        return developer.ServiceExtensionResponse.result(
          jsonEncode({'type': 'Success', 'elements': elements}),
        );
      } catch (e, stack) {
        return _errorResponse(e, stack);
      }
    });

    // 1b. Interactive Elements Structured (Enhanced inspect)
    developer
        .registerExtension('ext.flutter.flutter_skill.interactiveStructured',
            (method, parameters) async {
      try {
        final elements = _findInteractiveElementsStructured();
        return developer.ServiceExtensionResponse.result(
          jsonEncode({'type': 'Success', 'data': elements}),
        );
      } catch (e, stack) {
        return _errorResponse(e, stack);
      }
    });

    // 1c. Interactive Elements with Ref IDs (New inspect_interactive method)
    developer.registerExtension('ext.flutter.flutter_skill.inspectInteractive',
        (method, parameters) async {
      try {
        final elements = _findInteractiveElementsStructured();
        return developer.ServiceExtensionResponse.result(
          jsonEncode({'type': 'Success', 'data': elements}),
        );
      } catch (e, stack) {
        return _errorResponse(e, stack);
      }
    });

    // 2. Tap
    developer.registerExtension('ext.flutter.flutter_skill.tap',
        (method, parameters) async {
      try {
        final key = parameters['key'];
        final text = parameters['text'];
        final refId = parameters['ref'];
        final result =
            await _performTapWithDetails(key: key, text: text, refId: refId);
        return developer.ServiceExtensionResponse.result(jsonEncode(result));
      } catch (e, stack) {
        return _errorResponse(e, stack);
      }
    });

    // 3. Enter Text
    developer.registerExtension('ext.flutter.flutter_skill.enterText',
        (method, parameters) async {
      try {
        final key = parameters['key'];
        final text = parameters['text'];
        final refId = parameters['ref'];
        if (text == null) {
          return developer.ServiceExtensionResponse.result(jsonEncode({
            'success': false,
            'error': {
              'code': ErrorCode.inputFailed,
              'message': 'Missing text parameter',
            },
          }));
        }
        final result = await _performEnterTextWithDetails(
            key: key, text: text, refId: refId);
        return developer.ServiceExtensionResponse.result(jsonEncode(result));
      } catch (e, stack) {
        return _errorResponse(e, stack);
      }
    });

    // 4. Scroll
    developer.registerExtension('ext.flutter.flutter_skill.scroll',
        (method, parameters) async {
      try {
        final key = parameters['key'];
        final text = parameters['text'];
        final result = await _performScroll(key: key, text: text);
        return developer.ServiceExtensionResponse.result(
          jsonEncode({
            'success': result['success'],
            'message': result['success'] == true
                ? 'Scroll successful'
                : (result['error'] ?? 'Scroll failed'),
          }),
        );
      } catch (e, stack) {
        return _errorResponse(e, stack);
      }
    });

    // ==================== UI INSPECTION EXTENSIONS ====================

    // 5. Get Widget Tree
    developer.registerExtension('ext.flutter.flutter_skill.getWidgetTree',
        (method, parameters) async {
      try {
        final maxDepth = int.tryParse(parameters['maxDepth'] ?? '10') ?? 10;
        final tree = _getWidgetTree(maxDepth: maxDepth);
        return developer.ServiceExtensionResponse.result(
            jsonEncode({'tree': tree}));
      } catch (e, stack) {
        return _errorResponse(e, stack);
      }
    });

    // 6. Get Widget Properties
    developer.registerExtension('ext.flutter.flutter_skill.getWidgetProperties',
        (method, parameters) async {
      try {
        final key = parameters['key'];
        if (key == null) {
          return developer.ServiceExtensionResponse.error(
            developer.ServiceExtensionResponse.invalidParams,
            'Missing key',
          );
        }
        final properties = _getWidgetProperties(key);
        return developer.ServiceExtensionResponse.result(
            jsonEncode({'properties': properties}));
      } catch (e, stack) {
        return _errorResponse(e, stack);
      }
    });

    // 7. Get Text Content
    developer.registerExtension('ext.flutter.flutter_skill.getTextContent',
        (method, parameters) async {
      try {
        final textList = _getTextContent();
        return developer.ServiceExtensionResponse.result(
            jsonEncode({'texts': textList}));
      } catch (e, stack) {
        return _errorResponse(e, stack);
      }
    });

    // 8. Find By Type
    developer.registerExtension('ext.flutter.flutter_skill.findByType',
        (method, parameters) async {
      try {
        final type = parameters['type'];
        if (type == null) {
          return developer.ServiceExtensionResponse.error(
            developer.ServiceExtensionResponse.invalidParams,
            'Missing type',
          );
        }
        final elements = _findByType(type);
        return developer.ServiceExtensionResponse.result(
            jsonEncode({'elements': elements}));
      } catch (e, stack) {
        return _errorResponse(e, stack);
      }
    });

    // ==================== MORE INTERACTIONS ====================

    // 9. Long Press
    developer.registerExtension('ext.flutter.flutter_skill.longPress',
        (method, parameters) async {
      try {
        final key = parameters['key'];
        final text = parameters['text'];
        final duration = int.tryParse(parameters['duration'] ?? '500') ?? 500;
        final success =
            await _performLongPress(key: key, text: text, duration: duration);
        return developer.ServiceExtensionResponse.result(
          jsonEncode({
            'success': success,
            'message': success ? 'Long press successful' : 'Element not found'
          }),
        );
      } catch (e, stack) {
        return _errorResponse(e, stack);
      }
    });

    // 10. Swipe
    developer.registerExtension('ext.flutter.flutter_skill.swipe',
        (method, parameters) async {
      try {
        final direction = parameters['direction'] ?? 'up';
        final distance =
            double.tryParse(parameters['distance'] ?? '300') ?? 300;
        final key = parameters['key'];
        final success = await _performSwipe(
            direction: direction, distance: distance, key: key);
        return developer.ServiceExtensionResponse.result(
          jsonEncode({
            'success': success,
            'message': success ? 'Swipe successful' : 'Swipe failed'
          }),
        );
      } catch (e, stack) {
        return _errorResponse(e, stack);
      }
    });

    // 11. Drag
    developer.registerExtension('ext.flutter.flutter_skill.drag',
        (method, parameters) async {
      try {
        final fromKey = parameters['fromKey'];
        final toKey = parameters['toKey'];
        final success = await _performDrag(fromKey: fromKey, toKey: toKey);
        return developer.ServiceExtensionResponse.result(
          jsonEncode({
            'success': success,
            'message': success ? 'Drag successful' : 'Drag failed'
          }),
        );
      } catch (e, stack) {
        return _errorResponse(e, stack);
      }
    });

    // 12. Double Tap
    developer.registerExtension('ext.flutter.flutter_skill.doubleTap',
        (method, parameters) async {
      try {
        final key = parameters['key'];
        final text = parameters['text'];
        final success = await _performDoubleTap(key: key, text: text);
        return developer.ServiceExtensionResponse.result(
          jsonEncode({
            'success': success,
            'message': success ? 'Double tap successful' : 'Element not found'
          }),
        );
      } catch (e, stack) {
        return _errorResponse(e, stack);
      }
    });

    // ==================== STATE & VALIDATION ====================

    // 13. Get Text Value
    developer.registerExtension('ext.flutter.flutter_skill.getTextValue',
        (method, parameters) async {
      try {
        final key = parameters['key'];
        if (key == null) {
          return developer.ServiceExtensionResponse.error(
            developer.ServiceExtensionResponse.invalidParams,
            'Missing key',
          );
        }
        final value = _getTextFieldValue(key);
        return developer.ServiceExtensionResponse.result(
            jsonEncode({'value': value}));
      } catch (e, stack) {
        return _errorResponse(e, stack);
      }
    });

    // 14. Get Checkbox State
    developer.registerExtension('ext.flutter.flutter_skill.getCheckboxState',
        (method, parameters) async {
      try {
        final key = parameters['key'];
        if (key == null) {
          return developer.ServiceExtensionResponse.error(
            developer.ServiceExtensionResponse.invalidParams,
            'Missing key',
          );
        }
        final state = _getCheckboxState(key);
        return developer.ServiceExtensionResponse.result(
            jsonEncode({'checked': state}));
      } catch (e, stack) {
        return _errorResponse(e, stack);
      }
    });

    // 15. Get Slider Value
    developer.registerExtension('ext.flutter.flutter_skill.getSliderValue',
        (method, parameters) async {
      try {
        final key = parameters['key'];
        if (key == null) {
          return developer.ServiceExtensionResponse.error(
            developer.ServiceExtensionResponse.invalidParams,
            'Missing key',
          );
        }
        final value = _getSliderValue(key);
        return developer.ServiceExtensionResponse.result(
            jsonEncode({'value': value}));
      } catch (e, stack) {
        return _errorResponse(e, stack);
      }
    });

    // 16. Wait For Element
    developer.registerExtension('ext.flutter.flutter_skill.waitForElement',
        (method, parameters) async {
      try {
        final key = parameters['key'];
        final text = parameters['text'];
        final timeout = int.tryParse(parameters['timeout'] ?? '5000') ?? 5000;
        final found =
            await _waitForElement(key: key, text: text, timeout: timeout);
        return developer.ServiceExtensionResponse.result(
          jsonEncode({
            'found': found,
            'message': found ? 'Element found' : 'Timeout waiting for element'
          }),
        );
      } catch (e, stack) {
        return _errorResponse(e, stack);
      }
    });

    // 17. Wait For Gone
    developer.registerExtension('ext.flutter.flutter_skill.waitForGone',
        (method, parameters) async {
      try {
        final key = parameters['key'];
        final text = parameters['text'];
        final timeout = int.tryParse(parameters['timeout'] ?? '5000') ?? 5000;
        final gone = await _waitForGone(key: key, text: text, timeout: timeout);
        return developer.ServiceExtensionResponse.result(
          jsonEncode({
            'gone': gone,
            'message': gone ? 'Element is gone' : 'Element still present'
          }),
        );
      } catch (e, stack) {
        return _errorResponse(e, stack);
      }
    });

    // ==================== SCREENSHOT ====================

    // 18. Screenshot (with quality and maxWidth support)
    developer.registerExtension('ext.flutter.flutter_skill.screenshot',
        (method, parameters) async {
      try {
        final quality = double.tryParse(parameters['quality'] ?? '1.0') ?? 1.0;
        final maxWidth = int.tryParse(parameters['maxWidth'] ?? '');
        final base64Image =
            await _takeScreenshot(quality: quality, maxWidth: maxWidth);
        return developer.ServiceExtensionResponse.result(
            jsonEncode({'image': base64Image}));
      } catch (e, stack) {
        return _errorResponse(e, stack);
      }
    });

    // 18b. Screenshot Region
    developer.registerExtension('ext.flutter.flutter_skill.screenshotRegion',
        (method, parameters) async {
      try {
        final x = double.tryParse(parameters['x'] ?? '0') ?? 0;
        final y = double.tryParse(parameters['y'] ?? '0') ?? 0;
        final width = double.tryParse(parameters['width'] ?? '100') ?? 100;
        final height = double.tryParse(parameters['height'] ?? '100') ?? 100;
        final base64Image = await _takeRegionScreenshot(x, y, width, height);
        return developer.ServiceExtensionResponse.result(
            jsonEncode({'image': base64Image}));
      } catch (e, stack) {
        return _errorResponse(e, stack);
      }
    });

    // 19. Screenshot Element
    developer.registerExtension('ext.flutter.flutter_skill.screenshotElement',
        (method, parameters) async {
      try {
        final key = parameters['key'];
        if (key == null) {
          return developer.ServiceExtensionResponse.error(
            developer.ServiceExtensionResponse.invalidParams,
            'Missing key',
          );
        }
        final base64Image = await _takeElementScreenshot(key);
        return developer.ServiceExtensionResponse.result(
            jsonEncode({'image': base64Image}));
      } catch (e, stack) {
        return _errorResponse(e, stack);
      }
    });

    // ==================== NAVIGATION ====================

    // 20. Get Current Route
    developer.registerExtension('ext.flutter.flutter_skill.getCurrentRoute',
        (method, parameters) async {
      try {
        final route = _getCurrentRoute();
        return developer.ServiceExtensionResponse.result(
            jsonEncode({'route': route}));
      } catch (e, stack) {
        return _errorResponse(e, stack);
      }
    });

    // 21. Go Back
    developer.registerExtension('ext.flutter.flutter_skill.goBack',
        (method, parameters) async {
      try {
        final success = _goBack();
        return developer.ServiceExtensionResponse.result(
          jsonEncode({
            'success': success,
            'message': success ? 'Navigated back' : 'Cannot go back'
          }),
        );
      } catch (e, stack) {
        return _errorResponse(e, stack);
      }
    });

    // 22. Get Navigation Stack
    developer.registerExtension('ext.flutter.flutter_skill.getNavigationStack',
        (method, parameters) async {
      try {
        final stack = _getNavigationStack();
        return developer.ServiceExtensionResponse.result(
            jsonEncode({'stack': stack}));
      } catch (e, stack) {
        return _errorResponse(e, stack);
      }
    });

    // ==================== TEST INDICATORS ====================

    // Enable Test Indicators
    developer.registerExtension('ext.flutter.flutter_skill.enableIndicators',
        (method, parameters) async {
      try {
        _indicatorsEnabled = true;
        _indicatorOverlay ??= TestIndicatorOverlay();
        _indicatorOverlay!.enable();

        // Optional: set style
        final styleParam = parameters['style'];
        if (styleParam != null) {
          final style = IndicatorStyle.values.firstWhere(
            (s) => s.name == styleParam,
            orElse: () => IndicatorStyle.standard,
          );
          _indicatorOverlay!.setStyle(style);
        }

        return developer.ServiceExtensionResponse.result(
          jsonEncode({
            'success': true,
            'enabled': true,
            'style': _indicatorOverlay!._style.name,
          }),
        );
      } catch (e, stack) {
        return _errorResponse(e, stack);
      }
    });

    // Disable Test Indicators
    developer.registerExtension('ext.flutter.flutter_skill.disableIndicators',
        (method, parameters) async {
      try {
        _indicatorsEnabled = false;
        _indicatorOverlay?.disable();
        _indicatorOverlay = null;

        return developer.ServiceExtensionResponse.result(
          jsonEncode({
            'success': true,
            'enabled': false,
          }),
        );
      } catch (e, stack) {
        return _errorResponse(e, stack);
      }
    });

    // Get Indicator Status
    developer.registerExtension('ext.flutter.flutter_skill.getIndicatorStatus',
        (method, parameters) async {
      try {
        return developer.ServiceExtensionResponse.result(
          jsonEncode({
            'enabled': _indicatorsEnabled,
            'style': _indicatorOverlay?._style.name ?? 'standard',
          }),
        );
      } catch (e, stack) {
        return _errorResponse(e, stack);
      }
    });

    // ==================== PRESS KEY ====================

    developer.registerExtension('ext.flutter.flutter_skill.pressKey',
        (method, parameters) async {
      try {
        final key = parameters['key'];
        if (key == null || key.isEmpty) {
          return developer.ServiceExtensionResponse.result(
            jsonEncode({'success': false, 'error': 'Missing key parameter'}),
          );
        }
        final modifiers = (parameters['modifiers'] ?? '')
            .split(',')
            .where((s) => s.isNotEmpty)
            .toList();

        final keyMap = <String, LogicalKeyboardKey>{
          'enter': LogicalKeyboardKey.enter,
          'tab': LogicalKeyboardKey.tab,
          'escape': LogicalKeyboardKey.escape,
          'backspace': LogicalKeyboardKey.backspace,
          'delete': LogicalKeyboardKey.delete,
          'space': LogicalKeyboardKey.space,
          'up': LogicalKeyboardKey.arrowUp,
          'down': LogicalKeyboardKey.arrowDown,
          'left': LogicalKeyboardKey.arrowLeft,
          'right': LogicalKeyboardKey.arrowRight,
          'home': LogicalKeyboardKey.home,
          'end': LogicalKeyboardKey.end,
          'pageup': LogicalKeyboardKey.pageUp,
          'pagedown': LogicalKeyboardKey.pageDown,
        };

        final logicalKey = keyMap[key.toLowerCase()] ??
            LogicalKeyboardKey.findKeyByKeyId(key.codeUnitAt(0));

        if (logicalKey == null) {
          return developer.ServiceExtensionResponse.result(
            jsonEncode({'success': false, 'error': 'Unknown key: $key'}),
          );
        }

        // Build modifier key list (reserved for future modifier support)
        // ignore: unused_local_variable
        final isShift = modifiers.contains('shift');
        // ignore: unused_local_variable
        final isCtrl = modifiers.contains('ctrl');
        // ignore: unused_local_variable
        final isAlt = modifiers.contains('alt');
        // ignore: unused_local_variable
        final isMeta = modifiers.contains('meta');

        // Simulate key press through the focus system
        final focusNode = FocusManager.instance.primaryFocus;
        if (focusNode != null) {
          // Use HardwareKeyboard simulation
          // ignore: unused_local_variable
          final binding = WidgetsBinding.instance;
          // ignore: unused_local_variable
          final pointer = _pointerCounter++;

          // Create a RawKeyDownEvent and dispatch through the focus system
          // ignore: unused_local_variable
          final keyDown = KeyDownEvent(
            physicalKey: PhysicalKeyboardKey.findKeyByCode(logicalKey.keyId) ??
                PhysicalKeyboardKey.enter,
            logicalKey: logicalKey,
            timeStamp:
                Duration(milliseconds: DateTime.now().millisecondsSinceEpoch),
          );

          // Dispatch through ServicesBinding
          await ServicesBinding.instance.keyEventManager
              .handleKeyData(ui.KeyData(
            type: ui.KeyEventType.down,
            timeStamp:
                Duration(milliseconds: DateTime.now().millisecondsSinceEpoch),
            physical: (PhysicalKeyboardKey.findKeyByCode(logicalKey.keyId) ??
                    PhysicalKeyboardKey.enter)
                .usbHidUsage,
            logical: logicalKey.keyId,
            character: key.length == 1 ? key : null,
            synthesized: false,
          ));

          await Future.delayed(const Duration(milliseconds: 50));

          await ServicesBinding.instance.keyEventManager
              .handleKeyData(ui.KeyData(
            type: ui.KeyEventType.up,
            timeStamp:
                Duration(milliseconds: DateTime.now().millisecondsSinceEpoch),
            physical: (PhysicalKeyboardKey.findKeyByCode(logicalKey.keyId) ??
                    PhysicalKeyboardKey.enter)
                .usbHidUsage,
            logical: logicalKey.keyId,
            character: null,
            synthesized: false,
          ));
        }

        return developer.ServiceExtensionResponse.result(
          jsonEncode({'success': true, 'message': 'Key pressed: $key'}),
        );
      } catch (e, stack) {
        return _errorResponse(e, stack);
      }
    });

    // ==================== DEBUG & LOGS ====================

    // 23. Get Logs
    developer.registerExtension('ext.flutter.flutter_skill.getLogs',
        (method, parameters) async {
      try {
        return developer.ServiceExtensionResponse.result(
            jsonEncode({'logs': _logs}));
      } catch (e, stack) {
        return _errorResponse(e, stack);
      }
    });

    // 24. Get Errors
    developer.registerExtension('ext.flutter.flutter_skill.getErrors',
        (method, parameters) async {
      try {
        return developer.ServiceExtensionResponse.result(
            jsonEncode({'errors': _errors}));
      } catch (e, stack) {
        return _errorResponse(e, stack);
      }
    });

    // 25. Clear Logs
    developer.registerExtension('ext.flutter.flutter_skill.clearLogs',
        (method, parameters) async {
      try {
        _logs.clear();
        _errors.clear();
        return developer.ServiceExtensionResponse.result(
            jsonEncode({'success': true}));
      } catch (e, stack) {
        return _errorResponse(e, stack);
      }
    });

    // 26. Get Performance
    developer.registerExtension('ext.flutter.flutter_skill.getPerformance',
        (method, parameters) async {
      try {
        final perf = _getPerformanceMetrics();
        return developer.ServiceExtensionResponse.result(jsonEncode(perf));
      } catch (e, stack) {
        return _errorResponse(e, stack);
      }
    });

    // ==================== COORDINATE-BASED ACTIONS ====================

    // 27. Tap At Coordinates
    developer.registerExtension('ext.flutter.flutter_skill.tapAt',
        (method, parameters) async {
      try {
        final x = double.tryParse(parameters['x'] ?? '0') ?? 0;
        final y = double.tryParse(parameters['y'] ?? '0') ?? 0;
        await _performTapAt(x, y);
        return developer.ServiceExtensionResponse.result(
          jsonEncode({'success': true, 'message': 'Tapped at ($x, $y)'}),
        );
      } catch (e, stack) {
        return _errorResponse(e, stack);
      }
    });

    // 28. Long Press At Coordinates
    developer.registerExtension('ext.flutter.flutter_skill.longPressAt',
        (method, parameters) async {
      try {
        final x = double.tryParse(parameters['x'] ?? '0') ?? 0;
        final y = double.tryParse(parameters['y'] ?? '0') ?? 0;
        final duration = int.tryParse(parameters['duration'] ?? '500') ?? 500;
        await _performLongPressAt(x, y, duration: duration);
        return developer.ServiceExtensionResponse.result(
          jsonEncode({'success': true, 'message': 'Long pressed at ($x, $y)'}),
        );
      } catch (e, stack) {
        return _errorResponse(e, stack);
      }
    });

    // 29. Swipe Coordinates
    developer.registerExtension('ext.flutter.flutter_skill.swipeCoordinates',
        (method, parameters) async {
      try {
        final startX = double.tryParse(parameters['startX'] ?? '0') ?? 0;
        final startY = double.tryParse(parameters['startY'] ?? '0') ?? 0;
        final endX = double.tryParse(parameters['endX'] ?? '0') ?? 0;
        final endY = double.tryParse(parameters['endY'] ?? '0') ?? 0;
        final duration = int.tryParse(parameters['duration'] ?? '300') ?? 300;
        await _performSwipeCoordinates(startX, startY, endX, endY,
            duration: duration);
        return developer.ServiceExtensionResponse.result(
          jsonEncode({
            'success': true,
            'message': 'Swiped from ($startX, $startY) to ($endX, $endY)'
          }),
        );
      } catch (e, stack) {
        return _errorResponse(e, stack);
      }
    });

    // 30. Edge Swipe (for drawer menus, back gestures)
    developer.registerExtension('ext.flutter.flutter_skill.edgeSwipe',
        (method, parameters) async {
      try {
        final edge = parameters['edge'] ?? 'left';
        final direction = parameters['direction'] ?? 'right';
        final distance =
            double.tryParse(parameters['distance'] ?? '200') ?? 200;
        final success = await _performEdgeSwipe(
            edge: edge, direction: direction, distance: distance);
        return developer.ServiceExtensionResponse.result(
          jsonEncode({
            'success': success,
            'message': success ? 'Edge swipe successful' : 'Edge swipe failed'
          }),
        );
      } catch (e, stack) {
        return _errorResponse(e, stack);
      }
    });

    // ==================== PERFORMANCE & MEMORY ====================

    // 30. Get Frame Stats
    developer.registerExtension('ext.flutter.flutter_skill.getFrameStats',
        (method, parameters) async {
      try {
        final stats = _getFrameStats();
        return developer.ServiceExtensionResponse.result(jsonEncode(stats));
      } catch (e, stack) {
        return _errorResponse(e, stack);
      }
    });

    // 25. Log HTTP Request (manual API for apps to call)
    developer.registerExtension('ext.flutter.flutter_skill.logHttpRequest',
        (method, parameters) async {
      try {
        final entry = <String, dynamic>{
          'method': parameters['method'] ?? 'GET',
          'url': parameters['url'] ?? '',
          'status_code': int.tryParse(parameters['status_code'] ?? ''),
          'duration_ms': int.tryParse(parameters['duration_ms'] ?? ''),
          'response_body': parameters['response_body'],
          'error': parameters['error'],
          'timestamp': DateTime.now().toIso8601String(),
        };
        // Remove null values
        entry.removeWhere((_, v) => v == null);
        _httpRequests.add(entry);
        if (_httpRequests.length > 500) {
          _httpRequests.removeAt(0);
        }
        return developer.ServiceExtensionResponse.result(
            jsonEncode({'logged': true, 'total': _httpRequests.length}));
      } catch (e, stack) {
        return _errorResponse(e, stack);
      }
    });

    // 26. Get HTTP Requests (manually logged)
    developer.registerExtension('ext.flutter.flutter_skill.getHttpRequests',
        (method, parameters) async {
      try {
        final limit = int.tryParse(parameters['limit'] ?? '50') ?? 50;
        final offset = int.tryParse(parameters['offset'] ?? '0') ?? 0;
        final paged = _httpRequests.skip(offset).take(limit).toList();
        return developer.ServiceExtensionResponse.result(jsonEncode({
          'requests': paged,
          'total': _httpRequests.length,
          'returned': paged.length,
          'offset': offset,
          'limit': limit,
        }));
      } catch (e, stack) {
        return _errorResponse(e, stack);
      }
    });

    // 27. Clear HTTP Requests
    developer.registerExtension('ext.flutter.flutter_skill.clearHttpRequests',
        (method, parameters) async {
      try {
        final count = _httpRequests.length;
        _httpRequests.clear();
        return developer.ServiceExtensionResponse.result(
            jsonEncode({'cleared': count}));
      } catch (e, stack) {
        return _errorResponse(e, stack);
      }
    });

    // Setup error handler
    FlutterError.onError = (FlutterErrorDetails details) {
      _errors.add({
        'error': details.exception.toString(),
        'stack': details.stack?.toString(),
        'library': details.library,
        'context': details.context?.toString(),
        'timestamp': DateTime.now().toIso8601String(),
      });
    };
  }

  static developer.ServiceExtensionResponse _errorResponse(
      Object e, StackTrace stack) {
    return developer.ServiceExtensionResponse.error(
      developer.ServiceExtensionResponse.extensionError,
      '$e\n$stack',
    );
  }

  // ==================== ELEMENT FINDING ====================

  static Element? _findElementByKey(String key) {
    final matches = <Element>[];
    void visit(Element element) {
      final widget = element.widget;
      if (widget.key is ValueKey<String> &&
          (widget.key as ValueKey<String>).value == key) {
        matches.add(element);
      }
      element.visitChildren(visit);
    }

    final binding = WidgetsBinding.instance;
    // ignore: invalid_use_of_protected_member
    if (binding.rootElement != null) {
      visit(binding.rootElement!);
    }
    return _preferTopmostMatch(matches);
  }

  static Element? _findElementByText(String text) {
    final matches = <Element>[];
    void visit(Element element) {
      final widget = element.widget;
      if (widget is Text && widget.data == text) {
        matches.add(element);
      } else if (widget is RichText && widget.text.toPlainText() == text) {
        matches.add(element);
      }
      element.visitChildren(visit);
    }

    final binding = WidgetsBinding.instance;
    // ignore: invalid_use_of_protected_member
    if (binding.rootElement != null) {
      visit(binding.rootElement!);
    }
    return _preferTopmostMatch(matches);
  }

  /// Picks the best match among duplicates that can appear across stacked
  /// routes/overlays.
  ///
  /// The element tree is walked in pre-order, so a background route (mounted
  /// first, still alive underneath a pushed route) is collected *before* the
  /// foreground route. Returning the first match would therefore tap an element
  /// that is invisible behind the current screen — e.g. a tab label on the
  /// visible screen that also exists as a list subtitle on the screen behind it.
  ///
  /// In Overlay/Navigator order the foreground route is mounted last, so it is
  /// visited last. Returning the last match targets the screen the user actually
  /// sees. (A hit-test at each candidate's center would be even more precise and
  /// could be layered on top of this later.)
  static Element? _preferTopmostMatch(List<Element> matches) {
    if (matches.isEmpty) return null;
    return matches.last;
  }

  static Element? _findElement({String? key, String? text}) {
    if (key != null) return _findElementByKey(key);
    if (text != null) return _findElementByText(text);
    return null;
  }

  /// Find element by ref ID using caching and semantic ref system
  static Element? _findElementByRefId(String refId) {
    // Check if this is a legacy ref format (btn_0, tf_1, etc.)
    if (SemanticRefGenerator.isLegacyRef(refId)) {
      return _findElementByLegacyRef(refId);
    }

    // First, try cached element
    final cachedElement = SemanticRefGenerator.getCachedElement(refId);
    if (cachedElement != null) {
      final weakRef = cachedElement['element'] as WeakReference<Element>?;
      final element = weakRef?.target;
      if (element != null) {
        return element;
      }
    }

    // Check last inspect result cache
    if (_lastInspectResult != null && _lastInspectResult!.containsKey(refId)) {
      final targetElementData = _lastInspectResult![refId]!;

      // Extract bounds to find the element at center position
      final bounds = targetElementData['bounds'] as Map<String, dynamic>?;
      if (bounds != null) {
        final x = bounds['x'] as int? ?? 0;
        final y = bounds['y'] as int? ?? 0;
        final w = bounds['w'] as int? ?? 0;
        final h = bounds['h'] as int? ?? 0;

        if (w > 0 && h > 0) {
          final centerX = x + w / 2;
          final centerY = y + h / 2;
          return _findElementAtPosition(Offset(centerX, centerY));
        }
      }

      // Fallback: try to find by text, label, or key if available
      final text = targetElementData['text'] as String?;
      final label = targetElementData['label'] as String?;
      final key = targetElementData['key'] as String?;

      if (key != null) {
        final found = _findElementByKey(key);
        if (found != null) return found;
      }

      if (text != null) {
        final found = _findElementByText(text);
        if (found != null) return found;
      }

      if (label != null) {
        final found = _findElementByText(label);
        if (found != null) return found;
      }
    }

    // Handle elem_NNN numeric IDs from get_interactable_elements
    if (refId.startsWith('elem_')) {
      final freshElements = _findInteractiveElements();
      final match = freshElements.firstWhere(
        (e) => e['id'] == refId,
        orElse: () => {},
      );
      if (match.isNotEmpty) {
        final bounds = match['bounds'] as Map<String, dynamic>?;
        if (bounds != null) {
          final x = (bounds['x'] as num?)?.toDouble() ?? 0;
          final y = (bounds['y'] as num?)?.toDouble() ?? 0;
          final w = (bounds['width'] as num?)?.toDouble() ?? 0;
          final h = (bounds['height'] as num?)?.toDouble() ?? 0;
          if (w > 0 && h > 0) {
            return _findElementAtPosition(Offset(x + w / 2, y + h / 2));
          }
        }
      }
      return null;
    }

    // Cache miss - do fresh inspect to rebuild cache
    final structured = _findInteractiveElementsStructured();
    final elements = structured['elements'] as List<dynamic>? ?? [];

    // Find the element with matching ref ID
    Map<String, dynamic>? targetElementData;
    for (final elementData in elements) {
      if (elementData is Map<String, dynamic> && elementData['ref'] == refId) {
        targetElementData = elementData;
        break;
      }
    }

    if (targetElementData == null) return null;

    // Extract bounds to find the element at center position
    final bounds = targetElementData['bounds'] as Map<String, dynamic>?;
    if (bounds != null) {
      final x = bounds['x'] as int? ?? 0;
      final y = bounds['y'] as int? ?? 0;
      final w = bounds['w'] as int? ?? 0;
      final h = bounds['h'] as int? ?? 0;

      if (w > 0 && h > 0) {
        final centerX = x + w / 2;
        final centerY = y + h / 2;
        return _findElementAtPosition(Offset(centerX, centerY));
      }
    }

    return null;
  }

  /// Handle legacy ref format for backward compatibility
  static Element? _findElementByLegacyRef(String refId) {
    final legacyData = SemanticRefGenerator.parseLegacyRef(refId);
    if (legacyData == null) return null;

    // Re-run inspect to get current elements
    final structured = _findInteractiveElementsStructured();
    final elements = structured['elements'] as List<dynamic>? ?? [];

    final role = legacyData['role'] as String?;
    final index = legacyData['index'] as int? ?? 0;

    if (role == null) return null;

    // Find elements of matching semantic role and get by index
    final matchingElements = <Map<String, dynamic>>[];
    for (final elementData in elements) {
      if (elementData is Map<String, dynamic>) {
        final refId = elementData['ref'] as String?;
        if (refId != null && refId.startsWith('$role:')) {
          matchingElements.add(elementData);
        }
      }
    }

    if (matchingElements.isEmpty || index >= matchingElements.length) {
      return null;
    }

    // Get element at legacy index
    final targetElementData = matchingElements[index];

    // Find by ref ID using the new system
    final newRefId = targetElementData['ref'] as String?;
    if (newRefId != null) {
      return _findElementByRefId(newRefId);
    }

    return null;
  }

  /// Find element at a specific position by traversing the widget tree
  static Element? _findElementAtPosition(Offset position) {
    Element? found;

    void visit(Element element) {
      if (found != null) return;

      final renderObject = element.renderObject;
      if (renderObject is RenderBox && renderObject.hasSize) {
        final offset = renderObject.localToGlobal(Offset.zero);
        final size = renderObject.size;

        final bounds =
            Rect.fromLTWH(offset.dx, offset.dy, size.width, size.height);
        if (bounds.contains(position)) {
          // Check if this is an interactive element
          final widget = element.widget;
          if (_isInteractiveWidget(widget)) {
            found = element;
            return;
          }
        }
      }

      element.visitChildren(visit);
    }

    final binding = WidgetsBinding.instance;
    // ignore: invalid_use_of_protected_member
    if (binding.rootElement != null) {
      visit(binding.rootElement!);
    }
    return found;
  }

  /// Check if a widget is interactive
  static bool _isInteractiveWidget(Widget widget) {
    return widget is ElevatedButton ||
        widget is TextButton ||
        widget is OutlinedButton ||
        widget is IconButton ||
        widget is FloatingActionButton ||
        widget is TextField ||
        widget is TextFormField ||
        widget is Checkbox ||
        widget is Switch ||
        widget is Slider ||
        widget is DropdownButton ||
        (widget is InkWell && widget.onTap != null) ||
        (widget is GestureDetector && widget.onTap != null) ||
        widget is ListTile;
  }

  /// Helper method to enter text into a specific element
  static Future<Map<String, dynamic>> _enterTextIntoElement(
      Element element, String text,
      {required String method}) async {
    final renderObject = element.renderObject;
    if (renderObject is! RenderBox) {
      return {
        'success': false,
        'error': {
          'code': ErrorCode.elementNotVisible,
          'message': 'TextField has no valid render box',
        },
        'method': method,
      };
    }

    final center =
        renderObject.localToGlobal(renderObject.size.center(Offset.zero));

    // Show indicator if enabled
    if (_indicatorsEnabled && _indicatorOverlay != null) {
      final bounds = Rect.fromLTWH(
        renderObject.localToGlobal(Offset.zero).dx,
        renderObject.localToGlobal(Offset.zero).dy,
        renderObject.size.width,
        renderObject.size.height,
      );
      _indicatorOverlay!.showTextInput(bounds, hint: "Entering text: '$text'");
    }

    await _dispatchTap(center);
    await Future.delayed(const Duration(milliseconds: 200));

    EditableTextState? editableTextState;
    void findEditable(Element e) {
      if (editableTextState != null) return;
      if (e is StatefulElement && e.state is EditableTextState) {
        editableTextState = e.state as EditableTextState;
        return;
      }
      e.visitChildren(findEditable);
    }

    try {
      findEditable(element);
    } catch (_) {
      // Element tree may be partially unmounted
    }

    if (editableTextState != null) {
      editableTextState!.updateEditingValue(TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      ));
      _log('Entered text "$text" using $method');
      return {
        'success': true,
        'message': 'Text entered successfully',
        'method': method,
        'enteredText': text,
      };
    }

    SystemChannels.textInput.invokeMethod('TextInput.setEditingState', {
      'text': text,
      'selectionBase': text.length,
      'selectionExtent': text.length,
      'composingBase': -1,
      'composingExtent': -1,
    });
    _log('Text input sent via channel');

    return {
      'success': true,
      'message': 'Text entered via system channel',
      'method': method,
      'enteredText': text,
    };
  }

  // ==================== ACTIONS ====================

  // ignore: unused_element
  static Future<bool> _performTap({String? key, String? text}) async {
    final element = _findElement(key: key, text: text);
    if (element == null) {
      _log('Element not found for tap (key: $key, text: $text)');
      return false;
    }

    final renderObject = element.renderObject;
    if (renderObject is! RenderBox || !renderObject.hasSize) {
      _log('RenderObject is not a valid RenderBox');
      return false;
    }

    final center =
        renderObject.localToGlobal(renderObject.size.center(Offset.zero));
    _log('Tapping at $center (key: $key, text: $text)');

    await _dispatchTap(center);
    _log('Tap completed on (key: $key, text: $text)');
    return true;
  }

  /// Enhanced tap with detailed error information and suggestions
  static Future<Map<String, dynamic>> _performTapWithDetails(
      {String? key, String? text, String? refId}) async {
    Element? element;

    // If refId is provided, find element by ref ID first
    if (refId != null) {
      element = _findElementByRefId(refId);
    }

    // Fallback to key/text search if ref not found or not provided
    if (element == null) {
      element = _findElement(key: key, text: text);
    }

    if (element == null) {
      final suggestions = <String>[];

      // Find similar keys if key was provided
      if (key != null) {
        final similarKeys = _findSimilarKeys(key);
        if (similarKeys.isNotEmpty) {
          suggestions
              .add('Similar keys found: ${similarKeys.take(5).toList()}');
        }
      }

      // Find similar text if text was provided
      if (text != null) {
        final similarTexts = _findSimilarTexts(text);
        if (similarTexts.isNotEmpty) {
          suggestions
              .add('Similar texts found: ${similarTexts.take(5).toList()}');
        }
      }

      suggestions.addAll([
        'Use inspect() to see available interactive elements',
        'Use get_widget_tree() to explore the widget hierarchy',
      ]);

      _log('Element not found for tap (key: $key, text: $text, ref: $refId)');
      final target = refId != null
          ? "ref '$refId'"
          : key != null
              ? "key '$key'"
              : "text '$text'";
      return {
        'success': false,
        'error': {
          'code': ErrorCode.elementNotFound,
          'message': 'No element matching $target found in widget tree',
        },
        'target': {'key': key, 'text': text, if (refId != null) 'ref': refId},
        'suggestions': suggestions,
      };
    }

    final renderObject = element.renderObject;
    if (renderObject is! RenderBox || !renderObject.hasSize) {
      return {
        'success': false,
        'error': {
          'code': ErrorCode.elementNotVisible,
          'message': 'Element found but has no valid render box',
        },
        'target': {'key': key, 'text': text},
        'suggestions': [
          'Element may be offscreen or not yet laid out',
          'Try waiting for the element to be visible'
        ],
      };
    }

    final center =
        renderObject.localToGlobal(renderObject.size.center(Offset.zero));

    // Reject off-screen coordinates — element may be from a non-active route
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final sw = view.physicalSize.width / view.devicePixelRatio;
    final sh = view.physicalSize.height / view.devicePixelRatio;
    if (center.dx < -50 ||
        center.dx > sw + 50 ||
        center.dy < -50 ||
        center.dy > sh + 50) {
      return {
        'success': false,
        'error': {
          'code': ErrorCode.elementNotVisible,
          'message': 'Element "${text ?? key ?? refId}" is off-screen '
              '(coords: ${center.dx.round()}, ${center.dy.round()}). '
              'It may belong to a different route. Navigate to the correct page first.',
        },
        'target': {'key': key, 'text': text},
        'position': {'x': center.dx.round(), 'y': center.dy.round()},
      };
    }

    _log('Tapping at $center (key: $key, text: $text)');

    // Show indicator if enabled
    if (_indicatorsEnabled && _indicatorOverlay != null) {
      final targetText = text ?? _extractTextFrom(element) ?? key ?? 'element';
      _indicatorOverlay!.showTap(center, hint: "Tapping '$targetText'");
    }

    await _dispatchTap(center);

    // Fallback: directly invoke the callback if the widget supports it
    _tryInvokeCallback(element);

    // Wait for frame to pump after callback invocation
    await Future.delayed(const Duration(milliseconds: 300));

    _log('Tap completed on (key: $key, text: $text)');

    return {
      'success': true,
      'message': 'Tap successful',
      'target': {'key': key, 'text': text},
      'position': {'x': center.dx.round(), 'y': center.dy.round()},
    };
  }

  /// Try to directly invoke the onPressed/onTap callback of a widget.
  /// This is a fallback for when pointer dispatch doesn't trigger the callback
  /// (e.g., when an overlay intercepts events or hit testing fails).
  static void _tryInvokeCallback(Element element) {
    if (!element.mounted) return;
    final widget = element.widget;

    if (widget is ElevatedButton && widget.onPressed != null) {
      widget.onPressed!();
    } else if (widget is TextButton && widget.onPressed != null) {
      widget.onPressed!();
    } else if (widget is OutlinedButton && widget.onPressed != null) {
      widget.onPressed!();
    } else if (widget is IconButton && widget.onPressed != null) {
      widget.onPressed!();
    } else if (widget is FloatingActionButton && widget.onPressed != null) {
      widget.onPressed!();
    } else if (widget is InkWell && widget.onTap != null) {
      widget.onTap!();
    } else if (widget is GestureDetector && widget.onTap != null) {
      widget.onTap!();
    }
    // For other widget types, the pointer dispatch should handle it
  }

  /// Get all keys in the widget tree
  static List<String> _getAllKeys() {
    final keys = <String>[];

    void visit(Element element) {
      final widget = element.widget;
      if (widget.key is ValueKey<String>) {
        keys.add((widget.key as ValueKey<String>).value);
      }
      element.visitChildren(visit);
    }

    final binding = WidgetsBinding.instance;
    // ignore: invalid_use_of_protected_member
    if (binding.rootElement != null) {
      visit(binding.rootElement!);
    }
    return keys;
  }

  /// Find keys similar to the given key using simple substring matching
  static List<String> _findSimilarKeys(String targetKey) {
    final allKeys = _getAllKeys();
    final targetLower = targetKey.toLowerCase();

    // Score and sort by similarity
    final scored = <MapEntry<String, int>>[];
    for (final key in allKeys) {
      final keyLower = key.toLowerCase();
      int score = 0;

      // Exact substring match
      if (keyLower.contains(targetLower) || targetLower.contains(keyLower)) {
        score += 100;
      }

      // Common prefix
      int prefixLen = 0;
      for (int i = 0; i < targetLower.length && i < keyLower.length; i++) {
        if (targetLower[i] == keyLower[i])
          prefixLen++;
        else
          break;
      }
      score += prefixLen * 10;

      // Character overlap
      for (final char in targetLower.split('')) {
        if (keyLower.contains(char)) score += 1;
      }

      if (score > 5) {
        scored.add(MapEntry(key, score));
      }
    }

    scored.sort((a, b) => b.value.compareTo(a.value));
    return scored.map((e) => e.key).toList();
  }

  /// Find texts similar to the given text
  static List<String> _findSimilarTexts(String targetText) {
    final allTexts = _getTextContent()
        .map((t) => t['text'] as String?)
        .whereType<String>()
        .toList();
    final targetLower = targetText.toLowerCase();

    final scored = <MapEntry<String, int>>[];
    for (final text in allTexts) {
      final textLower = text.toLowerCase();
      int score = 0;

      if (textLower.contains(targetLower) || targetLower.contains(textLower)) {
        score += 100;
      }

      // Common words
      final targetWords = targetLower.split(RegExp(r'\s+'));
      final textWords = textLower.split(RegExp(r'\s+'));
      for (final word in targetWords) {
        if (textWords.contains(word)) score += 20;
      }

      if (score > 10 && text != targetText) {
        scored.add(MapEntry(text, score));
      }
    }

    scored.sort((a, b) => b.value.compareTo(a.value));
    return scored.map((e) => e.key).toList();
  }

  static Future<void> _dispatchTap(Offset position) async {
    final binding = WidgetsBinding.instance;
    final pointer = _pointerCounter++;

    // Show animated character walking to position and tapping
    if (_indicatorsEnabled && _indicatorOverlay != null) {
      // Use last position as starting point for walking animation
      final startPos = _lastCharacterPosition ?? position;
      _indicatorOverlay!.showCharacter(
        startPos,
        CharacterAction.tapping,
        hint: "Tapping",
        endPosition: position, // Character walks from startPos to position
      );
      _lastCharacterPosition = position; // Remember position for next action
      await Future.delayed(const Duration(milliseconds: 200));
    }

    binding.handlePointerEvent(
        PointerDownEvent(position: position, pointer: pointer));
    await Future.delayed(const Duration(milliseconds: 50));
    binding.handlePointerEvent(
        PointerUpEvent(position: position, pointer: pointer));

    // Show tap ripple after character
    if (_indicatorsEnabled && _indicatorOverlay != null) {
      _indicatorOverlay!.showTap(position);
    }

    await Future.delayed(const Duration(milliseconds: 100));
  }

  // ignore: unused_element
  static Future<bool> _performEnterText(
      {String? key, required String text}) async {
    final element = _findElement(key: key);
    if (element == null) {
      _log('TextField not found (key: $key)');
      return false;
    }

    final renderObject = element.renderObject;
    if (renderObject is! RenderBox) return false;

    final center =
        renderObject.localToGlobal(renderObject.size.center(Offset.zero));
    await _dispatchTap(center);
    await Future.delayed(const Duration(milliseconds: 200));

    EditableTextState? editableTextState;
    void findEditable(Element e) {
      if (editableTextState != null) return;
      if (e is StatefulElement && e.state is EditableTextState) {
        editableTextState = e.state as EditableTextState;
        return;
      }
      e.visitChildren(findEditable);
    }

    findEditable(element);

    if (editableTextState != null) {
      editableTextState!.updateEditingValue(TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      ));
      _log('Entered text "$text" (key: $key)');
      return true;
    }

    SystemChannels.textInput.invokeMethod('TextInput.setEditingState', {
      'text': text,
      'selectionBase': text.length,
      'selectionExtent': text.length,
      'composingBase': -1,
      'composingExtent': -1,
    });
    _log('Text input sent via channel');
    return true;
  }

  /// Find the currently focused TextField's EditableTextState
  static EditableTextState? _findFocusedTextField() {
    EditableTextState? focused;

    void visit(Element element) {
      if (focused != null) return;
      if (element is StatefulElement && element.state is EditableTextState) {
        final state = element.state as EditableTextState;
        if (state.widget.focusNode.hasFocus) {
          focused = state;
          return;
        }
      }
      element.visitChildren(visit);
    }

    final binding = WidgetsBinding.instance;
    // ignore: invalid_use_of_protected_member
    if (binding.rootElement != null) {
      visit(binding.rootElement!);
    }
    return focused;
  }

  /// Enhanced enter text with detailed error information
  static Future<Map<String, dynamic>> _performEnterTextWithDetails(
      {String? key, required String text, String? refId}) async {
    Element? element;

    // If refId is provided, find element by ref ID first
    if (refId != null) {
      element = _findElementByRefId(refId);
      if (element != null) {
        // Found by ref ID, proceed with text input
        return await _enterTextIntoElement(element, text, method: 'ref_id');
      }
    }

    // If no key or refId provided (null or empty), try the currently focused TextField
    if ((key == null || key.isEmpty) && refId == null) {
      final focusedField = _findFocusedTextField();
      if (focusedField != null) {
        focusedField.updateEditingValue(TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        ));
        _log('Entered text "$text" into focused TextField');
        return {
          'success': true,
          'message': 'Text entered into focused TextField',
          'method': 'focused_field',
          'enteredText': text,
        };
      }

      // No focused field found, try system channel as last resort
      try {
        await SystemChannels.textInput
            .invokeMethod('TextInput.setEditingState', {
          'text': text,
          'selectionBase': text.length,
          'selectionExtent': text.length,
          'composingBase': -1,
          'composingExtent': -1,
        });
        _log('Text input sent via system channel (no key, no focus)');
        return {
          'success': true,
          'message':
              'Text entered via system channel (no focused TextField found)',
          'method': 'system_channel',
          'enteredText': text,
        };
      } catch (e) {
        return {
          'success': false,
          'error': {
            'code': ErrorCode.elementNotFound,
            'message': 'No focused TextField found and system channel failed',
          },
          'suggestions': [
            'Tap on a TextField first to focus it, then call enter_text(text: "...")',
            'Or provide a key: enter_text(key: "field_key", text: "...")',
            'Or use ref: enter_text(ref: "tf_0", text: "...")',
            'Use inspect_interactive() to find TextField elements with ref IDs',
          ],
        };
      }
    }

    // Try to find element by key if provided
    if (key != null) {
      element = _findElement(key: key);
    }

    if (element == null) {
      final suggestions = <String>[];

      if (key != null) {
        final similarKeys = _findSimilarKeys(key);
        if (similarKeys.isNotEmpty) {
          suggestions
              .add('Similar keys found: ${similarKeys.take(5).toList()}');
        }

        // Find TextField keys specifically
        final textFieldKeys = _getAllKeys()
            .where((k) =>
                k.toLowerCase().contains('field') ||
                k.toLowerCase().contains('input') ||
                k.toLowerCase().contains('text'))
            .toList();
        if (textFieldKeys.isNotEmpty) {
          suggestions.add(
              'TextField keys available: ${textFieldKeys.take(5).toList()}');
        }
      }

      suggestions.add(
          'Use inspect_interactive() to find TextField elements with ref IDs');
      suggestions.add(
          'Or omit key/ref to enter text into the currently focused TextField');

      return {
        'success': false,
        'error': {
          'code': ErrorCode.elementNotFound,
          'message':
              'No TextField matching ${key != null ? "key '$key'" : (refId != null ? "ref '$refId'" : "criteria")} found',
        },
        'target': {'key': key, 'ref': refId},
        'suggestions': suggestions,
      };
    }

    // Use the helper method to enter text into the found element
    return await _enterTextIntoElement(element, text,
        method: key != null ? 'key' : 'fallback');
  }

  static Future<Map<String, dynamic>> _performScroll(
      {String? key, String? text}) async {
    final element = _findElement(key: key, text: text);
    if (element == null) {
      return {
        'success': false,
        'error': 'Element not found (key: $key, text: $text)'
      };
    }

    // Guard: context must still be mounted before calling ensureVisible.
    // An unmounted context throws StateError and can crash the VM Service
    // connection if the exception escapes the isolate's error zone.
    if (!element.mounted) {
      return {
        'success': false,
        'error':
            'Element context is no longer mounted (key: $key, text: $text)',
      };
    }

    try {
      await Scrollable.ensureVisible(
        element,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      ).timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          _log('scroll_to timed out after 5s (key: $key, text: $text)');
        },
      );
      _log('Scrolled to element (key: $key, text: $text)');
      return {'success': true};
    } catch (e) {
      _log('Scroll failed: $e');
      return {'success': false, 'error': e.toString()};
    }
  }

  static Future<bool> _performLongPress(
      {String? key, String? text, int duration = 500}) async {
    final element = _findElement(key: key, text: text);
    if (element == null) return false;

    final renderObject = element.renderObject;
    if (renderObject is! RenderBox || !renderObject.hasSize) return false;

    final center =
        renderObject.localToGlobal(renderObject.size.center(Offset.zero));
    final binding = WidgetsBinding.instance;
    final pointer = _pointerCounter++;

    binding.handlePointerEvent(
        PointerDownEvent(position: center, pointer: pointer));
    await Future.delayed(Duration(milliseconds: duration));
    binding
        .handlePointerEvent(PointerUpEvent(position: center, pointer: pointer));
    await Future.delayed(const Duration(milliseconds: 100));

    _log('Long press completed (key: $key, text: $text)');
    return true;
  }

  static Future<bool> _performSwipe(
      {required String direction, double distance = 300, String? key}) async {
    final binding = WidgetsBinding.instance;
    Offset start;

    if (key != null) {
      final element = _findElementByKey(key);
      if (element == null) return false;
      final renderObject = element.renderObject;
      if (renderObject is! RenderBox) return false;
      start = renderObject.localToGlobal(renderObject.size.center(Offset.zero));
    } else {
      // Use window size for global swipe
      final window = binding.platformDispatcher.views.first;
      final size = window.physicalSize / window.devicePixelRatio;
      start = Offset(size.width / 2, size.height / 2);
    }

    Offset delta;
    switch (direction.toLowerCase()) {
      case 'up':
        delta = Offset(0, -distance);
        break;
      case 'down':
        delta = Offset(0, distance);
        break;
      case 'left':
        delta = Offset(-distance, 0);
        break;
      case 'right':
        delta = Offset(distance, 0);
        break;
      default:
        return false;
    }

    final pointer = _pointerCounter++;
    final end = start + delta;

    binding.handlePointerEvent(
        PointerDownEvent(position: start, pointer: pointer));
    await Future.delayed(const Duration(milliseconds: 16));

    const steps = 10;
    for (int i = 1; i <= steps; i++) {
      final current = Offset.lerp(start, end, i / steps)!;
      binding.handlePointerEvent(PointerMoveEvent(
          position: current,
          pointer: pointer,
          delta: delta / steps.toDouble()));
      await Future.delayed(const Duration(milliseconds: 16));
    }

    binding.handlePointerEvent(PointerUpEvent(position: end, pointer: pointer));
    await Future.delayed(const Duration(milliseconds: 100));

    _log('Swipe $direction completed');
    return true;
  }

  static Future<bool> _performDrag({String? fromKey, String? toKey}) async {
    if (fromKey == null || toKey == null) return false;

    final fromElement = _findElementByKey(fromKey);
    final toElement = _findElementByKey(toKey);
    if (fromElement == null || toElement == null) return false;

    final fromRender = fromElement.renderObject;
    final toRender = toElement.renderObject;
    if (fromRender is! RenderBox || toRender is! RenderBox) return false;

    final start = fromRender.localToGlobal(fromRender.size.center(Offset.zero));
    final end = toRender.localToGlobal(toRender.size.center(Offset.zero));

    final binding = WidgetsBinding.instance;
    final pointer = _pointerCounter++;

    binding.handlePointerEvent(
        PointerDownEvent(position: start, pointer: pointer));
    await Future.delayed(const Duration(milliseconds: 100));

    const steps = 20;
    for (int i = 1; i <= steps; i++) {
      final current = Offset.lerp(start, end, i / steps)!;
      binding.handlePointerEvent(
          PointerMoveEvent(position: current, pointer: pointer));
      await Future.delayed(const Duration(milliseconds: 16));
    }

    binding.handlePointerEvent(PointerUpEvent(position: end, pointer: pointer));
    await Future.delayed(const Duration(milliseconds: 100));

    _log('Drag from $fromKey to $toKey completed');
    return true;
  }

  static Future<bool> _performDoubleTap({String? key, String? text}) async {
    final element = _findElement(key: key, text: text);
    if (element == null) return false;

    final renderObject = element.renderObject;
    if (renderObject is! RenderBox || !renderObject.hasSize) return false;

    final center =
        renderObject.localToGlobal(renderObject.size.center(Offset.zero));

    await _dispatchTap(center);
    await Future.delayed(const Duration(milliseconds: 50));
    await _dispatchTap(center);

    _log('Double tap completed (key: $key, text: $text)');
    return true;
  }

  // ==================== COORDINATE-BASED ACTIONS ====================

  static Future<void> _performTapAt(double x, double y) async {
    final position = Offset(x, y);
    await _dispatchTap(position);
    _log('Tap at coordinates ($x, $y) completed');
  }

  static Future<void> _performLongPressAt(double x, double y,
      {int duration = 500}) async {
    final position = Offset(x, y);
    final binding = WidgetsBinding.instance;
    final pointer = _pointerCounter++;

    // Show animated character holding
    if (_indicatorsEnabled && _indicatorOverlay != null) {
      _indicatorOverlay!.showCharacter(position, CharacterAction.holding,
          hint: "Long pressing");
      await Future.delayed(const Duration(milliseconds: 200));
      _indicatorOverlay!.showLongPress(
        position,
        Duration(milliseconds: duration),
      );
    }

    binding.handlePointerEvent(
        PointerDownEvent(position: position, pointer: pointer));
    await Future.delayed(Duration(milliseconds: duration));
    binding.handlePointerEvent(
        PointerUpEvent(position: position, pointer: pointer));
    await Future.delayed(const Duration(milliseconds: 100));

    _log('Long press at coordinates ($x, $y) completed');
  }

  static Future<void> _performSwipeCoordinates(
    double startX,
    double startY,
    double endX,
    double endY, {
    int duration = 300,
  }) async {
    final binding = WidgetsBinding.instance;
    final pointer = _pointerCounter++;

    final start = Offset(startX, startY);
    final end = Offset(endX, endY);
    final delta = end - start;

    // Show animated character swiping
    if (_indicatorsEnabled && _indicatorOverlay != null) {
      final direction = _getSwipeDirection(delta);
      _indicatorOverlay!.showCharacter(start, CharacterAction.swiping,
          hint: "Swiping $direction", endPosition: end);
      await Future.delayed(const Duration(milliseconds: 200));
      _indicatorOverlay!.showSwipe(start, end);
    }

    binding.handlePointerEvent(
        PointerDownEvent(position: start, pointer: pointer));
    await Future.delayed(const Duration(milliseconds: 16));

    final steps = (duration / 16).round().clamp(5, 30);
    final stepDuration = duration ~/ steps;

    for (int i = 1; i <= steps; i++) {
      final current = Offset.lerp(start, end, i / steps)!;
      binding.handlePointerEvent(PointerMoveEvent(
        position: current,
        pointer: pointer,
        delta: delta / steps.toDouble(),
      ));
      await Future.delayed(Duration(milliseconds: stepDuration));
    }

    binding.handlePointerEvent(PointerUpEvent(position: end, pointer: pointer));
    await Future.delayed(const Duration(milliseconds: 100));

    _log('Swipe from ($startX, $startY) to ($endX, $endY) completed');
  }

  static Future<bool> _performEdgeSwipe({
    required String edge,
    required String direction,
    double distance = 200,
  }) async {
    final binding = WidgetsBinding.instance;
    final view = binding.platformDispatcher.views.first;
    final screenSize = view.physicalSize / view.devicePixelRatio;

    double startX, startY;

    // Calculate start position based on edge
    switch (edge) {
      case 'left':
        startX = 0;
        startY = screenSize.height / 2;
        break;
      case 'right':
        startX = screenSize.width;
        startY = screenSize.height / 2;
        break;
      case 'top':
        startX = screenSize.width / 2;
        startY = 0;
        break;
      case 'bottom':
        startX = screenSize.width / 2;
        startY = screenSize.height;
        break;
      default:
        _log('Invalid edge: $edge');
        return false;
    }

    double endX = startX, endY = startY;

    // Calculate end position based on direction
    switch (direction) {
      case 'right':
        endX = startX + distance;
        break;
      case 'left':
        endX = startX - distance;
        break;
      case 'up':
        endY = startY - distance;
        break;
      case 'down':
        endY = startY + distance;
        break;
      default:
        _log('Invalid direction: $direction');
        return false;
    }

    // Clamp to screen bounds
    endX = endX.clamp(0, screenSize.width);
    endY = endY.clamp(0, screenSize.height);

    await _performSwipeCoordinates(startX, startY, endX, endY, duration: 300);
    _log(
        'Edge swipe from $edge edge, direction: $direction, distance: $distance');
    return true;
  }

  // ==================== PERFORMANCE ====================

  static Map<String, dynamic> _getFrameStats() {
    return {
      'timestamp': DateTime.now().toIso8601String(),
      'logCount': _logs.length,
      'errorCount': _errors.length,
      'message': 'Frame stats available via DevTools timeline',
    };
  }

  // ==================== UI INSPECTION ====================

  static List<Map<String, dynamic>> _findInteractiveElements() {
    final results = <Map<String, dynamic>>[];
    int elementCounter = 0;

    void visit(Element element, List<String> ancestors) {
      final widget = element.widget;
      String? type;
      String? text;
      String? key;
      String? semanticsLabel;
      String? tooltip;
      String? icon;

      if (widget.key is ValueKey<String>) {
        key = (widget.key as ValueKey<String>).value;
      }

      if (widget is ElevatedButton ||
          widget is TextButton ||
          widget is OutlinedButton ||
          widget is IconButton ||
          widget is FloatingActionButton) {
        type = 'Button';
        text = _extractTextFrom(element);
        if (widget is FloatingActionButton) {
          // Prefer child text, fall back to tooltip (e.g. FAB with Icon child)
          final fabTooltip = widget.tooltip;
          if ((text == null || text.isEmpty) &&
              fabTooltip != null &&
              fabTooltip.isNotEmpty) {
            text = fabTooltip;
          }
        } else if (widget is IconButton) {
          if (widget.icon is Icon) {
            icon = (widget.icon as Icon).icon?.toString();
          }
          // Use tooltip as label when there is no visible text
          final btnTooltip = widget.tooltip;
          if ((text == null || text.isEmpty) &&
              btnTooltip != null &&
              btnTooltip.isNotEmpty) {
            text = btnTooltip;
          }
        }
      } else if (widget is TextField || widget is TextFormField) {
        type = 'TextField';
      } else if (widget is Checkbox) {
        type = 'Checkbox';
      } else if (widget is Switch) {
        type = 'Switch';
      } else if (widget is Slider) {
        type = 'Slider';
      } else if (widget is DropdownButton) {
        type = 'Dropdown';
      } else if (widget is InkWell && widget.onTap != null) {
        type = 'Tappable';
        text = _extractTextFrom(element);
      } else if (widget is GestureDetector && widget.onTap != null) {
        type = 'Tappable';
        text = _extractTextFrom(element);
      } else if (widget is ListTile) {
        type = 'ListTile';
        text = _extractTextFrom(element);
      } else if (widget is BottomNavigationBarItem) {
        type = 'BottomNavItem';
      }

      // Extract semantics label
      if (widget is Semantics && widget.properties.label != null) {
        semanticsLabel = widget.properties.label;
      }

      // Extract tooltip
      if (widget is Tooltip) {
        tooltip = widget.message;
      }

      if (type != null) {
        elementCounter++;
        final entry = <String, dynamic>{
          'id': 'elem_${elementCounter.toString().padLeft(3, '0')}',
          'type': type,
          'widgetType': widget.runtimeType.toString(),
        };

        if (key != null) entry['key'] = key;
        if (text != null) entry['text'] = text;
        if (semanticsLabel != null) entry['semanticsLabel'] = semanticsLabel;
        if (tooltip != null) entry['tooltip'] = tooltip;
        if (icon != null) entry['icon'] = icon;

        // Add ancestors (last 3 meaningful ancestors)
        final meaningfulAncestors = ancestors
            .where((a) =>
                !a.startsWith('_') && a != 'Builder' && a != 'StatefulWidget')
            .toList();
        if (meaningfulAncestors.isNotEmpty) {
          entry['ancestors'] = meaningfulAncestors.reversed.take(3).toList();
        }

        // Add position and size from render object
        final renderObject = element.renderObject;
        if (renderObject is RenderBox && renderObject.hasSize) {
          final offset = renderObject.localToGlobal(Offset.zero);

          // Filter out elements from non-active routes (e.g. previous page still
          // in Navigator stack). Negative x means the page was pushed left.
          // Use a generous threshold to still include elements near the edge.
          final view = WidgetsBinding.instance.platformDispatcher.views.first;
          final sw = view.physicalSize.width / view.devicePixelRatio;
          final sh = view.physicalSize.height / view.devicePixelRatio;
          if (offset.dx < -sw * 0.5 ||
              offset.dx > sw * 1.5 ||
              offset.dy < -sh * 0.5 ||
              offset.dy > sh * 1.5) {
            element.visitChildren((child) => visit(child, ancestors));
            return;
          }

          // Helper function to safely convert double to int, handling Infinity/NaN
          int safeRound(double value) {
            if (!value.isFinite) return 0;
            return value.round();
          }

          // Detect if coordinates are reliable (not (0,0) unless widget is actually at origin)
          final isAtOrigin = offset.dx == 0 && offset.dy == 0;
          final hasValidSize =
              renderObject.size.width > 0 && renderObject.size.height > 0;
          final isFinite = offset.dx.isFinite && offset.dy.isFinite;

          // For TextFields, check if they're genuinely at origin or just not laid out
          bool coordinatesReliable = isFinite && hasValidSize;
          if (isAtOrigin && (widget is TextField || widget is TextFormField)) {
            // TextField at (0,0) is suspicious - likely not fully laid out
            // Check if there are other widgets to compare against
            coordinatesReliable = false;
          }

          entry['bounds'] = {
            'x': safeRound(offset.dx),
            'y': safeRound(offset.dy),
            'width': safeRound(renderObject.size.width),
            'height': safeRound(renderObject.size.height),
          };
          entry['center'] = {
            'x': safeRound(offset.dx + renderObject.size.width / 2),
            'y': safeRound(offset.dy + renderObject.size.height / 2),
          };
          entry['visible'] = hasValidSize;
          entry['coordinatesReliable'] = coordinatesReliable;

          // Add warning for unreliable coordinates
          if (!coordinatesReliable && isAtOrigin) {
            entry['warning'] =
                'Coordinates may be unreliable - widget might not be fully laid out. Use key or text for targeting.';
          }
        }

        results.add(entry);
      }

      // Build new ancestors list for children
      final widgetName = widget.runtimeType.toString();
      final newAncestors = [...ancestors, widgetName];

      element.visitChildren((child) => visit(child, newAncestors));
    }

    final binding = WidgetsBinding.instance;
    // ignore: invalid_use_of_protected_member
    if (binding.rootElement != null) {
      visit(binding.rootElement!, []);
    }

    return results;
  }

  /// Enhanced interactive elements discovery for better automation with semantic ref ID system.
  /// Returns structured data with semantic ref IDs, actions, bounds, and state information.
  static Map<String, dynamic> _findInteractiveElementsStructured() {
    final elements = <Map<String, dynamic>>[];
    final refCounts = <String, int>{};

    void visit(Element element) {
      final widget = element.widget;
      String? type;
      String? text;
      String? key;
      String? label;
      String? tooltip;
      List<String> actions = [];
      Map<String, dynamic> state = {};

      // Get widget key
      if (widget.key is ValueKey<String>) {
        key = (widget.key as ValueKey<String>).value;
      }

      // Identify widget type and available actions
      if (widget is ElevatedButton ||
          widget is TextButton ||
          widget is OutlinedButton ||
          widget is IconButton ||
          widget is FloatingActionButton) {
        type = widget.runtimeType.toString();
        text = _extractTextFrom(element);
        actions = ['tap', 'long_press'];

        // Get button state and tooltip fallback
        bool enabled = true;
        if (widget is FloatingActionButton) {
          enabled = widget.onPressed != null;
          final fabTooltip = widget.tooltip;
          if ((text == null || text.isEmpty) &&
              fabTooltip != null &&
              fabTooltip.isNotEmpty) {
            text = fabTooltip;
          }
        } else if (widget is IconButton) {
          enabled = widget.onPressed != null;
          final btnTooltip = widget.tooltip;
          if ((text == null || text.isEmpty) &&
              btnTooltip != null &&
              btnTooltip.isNotEmpty) {
            text = btnTooltip;
          }
        } else if (widget is ElevatedButton) {
          enabled = widget.onPressed != null;
        } else if (widget is TextButton) {
          enabled = widget.onPressed != null;
        } else if (widget is OutlinedButton) {
          enabled = widget.onPressed != null;
        }
        state['enabled'] = enabled;
      } else if (widget is TextField || widget is TextFormField) {
        type = widget.runtimeType.toString();
        actions = ['tap', 'enter_text'];

        // Get field label/hint - improved TextFormField label extraction
        if (widget is TextField) {
          label = widget.decoration?.labelText ?? widget.decoration?.hintText;
        } else if (widget is TextFormField) {
          // For TextFormField, try to extract the label from the decoration
          // by looking at the child TextField
          String? extractedLabel;

          void findTextField(Element e) {
            if (extractedLabel != null) return;
            final w = e.widget;
            if (w is TextField) {
              extractedLabel =
                  w.decoration?.labelText ?? w.decoration?.hintText;
              return;
            }
            e.visitChildren(findTextField);
          }

          findTextField(element);
          label = extractedLabel ?? 'Text Field';
        }

        // Get current text value
        final currentValue = _getTextFieldValueByElement(element);
        state['value'] = currentValue ?? '';
        state['enabled'] = true; // TextFields are typically enabled
      } else if (widget is Checkbox) {
        type = 'Checkbox';
        actions = ['tap'];

        state['value'] = widget.value ?? false;
        state['enabled'] = widget.onChanged != null;
      } else if (widget is Switch) {
        type = 'Switch';
        actions = ['tap'];

        state['value'] = widget.value;
        state['enabled'] = widget.onChanged != null;
      } else if (widget is Slider) {
        type = 'Slider';
        actions = ['tap', 'swipe']; // Can tap to set value or swipe to adjust

        state['value'] = widget.value;
        state['min'] = widget.min;
        state['max'] = widget.max;
        state['enabled'] = widget.onChanged != null;
      } else if (widget is DropdownButton) {
        type = 'DropdownButton';
        actions = ['tap'];

        // Get current value if available
        state['value'] = widget.value?.toString() ?? '';
        state['enabled'] = widget.onChanged != null;
      } else if (widget is InkWell && widget.onTap != null) {
        type = 'InkWell';
        text = _extractTextFrom(element);
        actions = ['tap', 'long_press'];

        state['enabled'] = true;
      } else if (widget is GestureDetector && widget.onTap != null) {
        type = 'GestureDetector';
        text = _extractTextFrom(element);
        actions = ['tap', 'long_press'];

        state['enabled'] = true;
      } else if (widget is ListTile) {
        type = 'ListTile';
        text = _extractTextFrom(element);
        actions = ['tap', 'long_press'];

        state['enabled'] = widget.enabled;
      }

      // Extract tooltip
      if (widget is Tooltip) {
        tooltip = widget.message;
      }

      // If this is an interactive element, add it to results
      if (type != null) {
        // Generate semantic ref ID using the new system
        final refId = SemanticRefGenerator.generateRefId(element, refCounts);

        final elementEntry = <String, dynamic>{
          'ref': refId,
          'type': type,
          'actions': actions,
        };

        // Add optional fields
        if (key != null && key.isNotEmpty) elementEntry['key'] = key;
        if (text != null && text.isNotEmpty) elementEntry['text'] = text;
        if (label != null && label.isNotEmpty) elementEntry['label'] = label;
        if (tooltip != null) elementEntry['tooltip'] = tooltip;

        // Add bounds information - improved with RenderBox
        final renderObject = element.renderObject;
        if (renderObject is RenderBox && renderObject.hasSize) {
          final offset = renderObject.localToGlobal(Offset.zero);
          final size = renderObject.size;

          // Filter out elements from non-active routes
          final view = WidgetsBinding.instance.platformDispatcher.views.first;
          final sw = view.physicalSize.width / view.devicePixelRatio;
          final sh = view.physicalSize.height / view.devicePixelRatio;
          if (offset.dx < -sw * 0.5 ||
              offset.dx > sw * 1.5 ||
              offset.dy < -sh * 0.5 ||
              offset.dy > sh * 1.5) {
            element.visitChildren(visit);
            return;
          }

          // Helper function to safely convert double to int
          int safeRound(double value) {
            if (!value.isFinite) return 0;
            return value.round();
          }

          final bounds = {
            'x': safeRound(offset.dx),
            'y': safeRound(offset.dy),
            'w': safeRound(size.width),
            'h': safeRound(size.height),
          };
          elementEntry['bounds'] = bounds;

          final isVisible = size.width > 0 &&
              size.height > 0 &&
              offset.dx.isFinite &&
              offset.dy.isFinite;
          state['visible'] = isVisible;

          // Cache element for performance optimization
          if (isVisible && refId.isNotEmpty) {
            SemanticRefGenerator.cacheElement(refId, element, bounds);
          }
        } else {
          // Element has no render box or size - set default bounds
          elementEntry['bounds'] = {'x': 0, 'y': 0, 'w': 0, 'h': 0};
          state['visible'] = false;
        }

        // Merge state information
        elementEntry.addAll(state);

        elements.add(elementEntry);
      }

      // Continue traversing children
      element.visitChildren(visit);
    }

    final binding = WidgetsBinding.instance;
    // ignore: invalid_use_of_protected_member
    if (binding.rootElement != null) {
      visit(binding.rootElement!);
    }

    // Generate summary based on ref counts
    final summaryParts = <String>[];
    refCounts.forEach((prefix, count) {
      switch (prefix) {
        case 'btn':
          summaryParts.add('$count button${count == 1 ? '' : 's'}');
          break;
        case 'tf':
          summaryParts.add('$count text field${count == 1 ? '' : 's'}');
          break;
        case 'sw':
          summaryParts.add('$count switch${count == 1 ? '' : 'es'}');
          break;
        case 'sl':
          summaryParts.add('$count slider${count == 1 ? '' : 's'}');
          break;
        case 'dd':
          summaryParts.add('$count dropdown${count == 1 ? '' : 's'}');
          break;
        case 'item':
          summaryParts.add('$count list item${count == 1 ? '' : 's'}');
          break;
        case 'lnk':
          summaryParts.add('$count link${count == 1 ? '' : 's'}');
          break;
      }
    });

    final summary = summaryParts.isEmpty
        ? 'No interactive elements found'
        : '${elements.length} interactive: ${summaryParts.join(', ')}';

    // Cache the result for server.dart usage
    _lastInspectResult = <String, Map<String, dynamic>>{};
    for (final element in elements) {
      final refId = element['ref'] as String?;
      if (refId != null) {
        _lastInspectResult![refId] = element;
      }
    }

    return {
      'elements': elements,
      'summary': summary,
    };
  }

  /// Helper method to get TextField value by Element (used by structured inspect)
  static String? _getTextFieldValueByElement(Element element) {
    EditableTextState? editableTextState;

    void findEditable(Element e) {
      if (editableTextState != null) return;
      if (e is StatefulElement && e.state is EditableTextState) {
        editableTextState = e.state as EditableTextState;
        return;
      }
      e.visitChildren(findEditable);
    }

    findEditable(element);

    if (editableTextState != null) {
      return editableTextState!.textEditingValue.text;
    }

    return null;
  }

  static Map<String, dynamic> _getWidgetTree({int maxDepth = 10}) {
    Map<String, dynamic> buildNode(Element element, int depth) {
      final widget = element.widget;
      final node = <String, dynamic>{
        'type': widget.runtimeType.toString(),
      };

      if (widget.key is ValueKey<String>) {
        node['key'] = (widget.key as ValueKey<String>).value;
      }

      if (widget is Text) {
        node['text'] = widget.data;
      }

      final renderObject = element.renderObject;
      if (renderObject is RenderBox && renderObject.hasSize) {
        node['size'] = {
          'width': renderObject.size.width,
          'height': renderObject.size.height
        };
        final offset = renderObject.localToGlobal(Offset.zero);
        node['position'] = {'x': offset.dx, 'y': offset.dy};
      }

      if (depth < maxDepth) {
        final children = <Map<String, dynamic>>[];
        element.visitChildren((child) {
          children.add(buildNode(child, depth + 1));
        });
        if (children.isNotEmpty) {
          node['children'] = children;
        }
      }

      return node;
    }

    final binding = WidgetsBinding.instance;
    // ignore: invalid_use_of_protected_member
    if (binding.rootElement != null) {
      return buildNode(binding.rootElement!, 0);
    }
    return {};
  }

  static Map<String, dynamic>? _getWidgetProperties(String key) {
    final element = _findElementByKey(key);
    if (element == null) return null;

    final widget = element.widget;
    final props = <String, dynamic>{
      'type': widget.runtimeType.toString(),
      'key': key,
    };

    final renderObject = element.renderObject;
    if (renderObject is RenderBox && renderObject.hasSize) {
      props['size'] = {
        'width': renderObject.size.width,
        'height': renderObject.size.height
      };
      final offset = renderObject.localToGlobal(Offset.zero);
      props['position'] = {'x': offset.dx, 'y': offset.dy};
      props['visible'] = renderObject.attached &&
          renderObject.size.width > 0 &&
          renderObject.size.height > 0;
    }

    if (widget is Text) {
      props['text'] = widget.data;
      props['style'] = widget.style?.toString();
    } else if (widget is Container) {
      props['color'] = widget.color?.toString();
      props['padding'] = widget.padding?.toString();
      props['margin'] = widget.margin?.toString();
    }

    return props;
  }

  static List<Map<String, dynamic>> _getTextContent() {
    final results = <Map<String, dynamic>>[];

    void visit(Element element) {
      final widget = element.widget;
      String? key;
      if (widget.key is ValueKey<String>) {
        key = (widget.key as ValueKey<String>).value;
      }

      if (widget is Text && widget.data != null) {
        results.add({
          'text': widget.data,
          if (key != null) 'key': key,
          'type': 'Text',
        });
      } else if (widget is RichText) {
        results.add({
          'text': widget.text.toPlainText(),
          if (key != null) 'key': key,
          'type': 'RichText',
        });
      }

      element.visitChildren(visit);
    }

    final binding = WidgetsBinding.instance;
    // ignore: invalid_use_of_protected_member
    if (binding.rootElement != null) {
      visit(binding.rootElement!);
    }

    return results;
  }

  static List<Map<String, dynamic>> _findByType(String typeName) {
    final results = <Map<String, dynamic>>[];

    void visit(Element element) {
      final widget = element.widget;
      final type = widget.runtimeType.toString();

      if (type.toLowerCase().contains(typeName.toLowerCase())) {
        String? key;
        if (widget.key is ValueKey<String>) {
          key = (widget.key as ValueKey<String>).value;
        }

        final node = <String, dynamic>{'type': type};
        if (key != null) node['key'] = key;

        final renderObject = element.renderObject;
        if (renderObject is RenderBox && renderObject.hasSize) {
          final offset = renderObject.localToGlobal(Offset.zero);

          // Helper function to safely convert double to int, handling Infinity/NaN
          int safeRound(double value) {
            if (!value.isFinite) return 0;
            return value.round();
          }

          // Use safeRound to prevent JSON serialization errors
          node['position'] = {
            'x': safeRound(offset.dx),
            'y': safeRound(offset.dy)
          };
          node['size'] = {
            'width': safeRound(renderObject.size.width),
            'height': safeRound(renderObject.size.height)
          };

          // Add coordinate reliability flag
          final isReliable = offset.dx.isFinite &&
              offset.dy.isFinite &&
              (offset.dx != 0 || offset.dy != 0) &&
              renderObject.size.width > 0 &&
              renderObject.size.height > 0;
          node['coordinatesReliable'] = isReliable;
        }

        results.add(node);
      }

      element.visitChildren(visit);
    }

    final binding = WidgetsBinding.instance;
    // ignore: invalid_use_of_protected_member
    if (binding.rootElement != null) {
      visit(binding.rootElement!);
    }

    return results;
  }

  // ==================== STATE & VALIDATION ====================

  static String? _getTextFieldValue(String key) {
    final element = _findElementByKey(key);
    if (element == null) return null;

    // First try: look for EditableTextState (TextField/TextFormField)
    EditableTextState? editableTextState;
    void findEditable(Element e) {
      if (editableTextState != null) return;
      if (e is StatefulElement && e.state is EditableTextState) {
        editableTextState = e.state as EditableTextState;
        return;
      }
      e.visitChildren(findEditable);
    }

    findEditable(element);

    if (editableTextState != null) {
      return editableTextState!.textEditingValue.text;
    }

    // Fallback: read child Text widget content (for buttons, labels, etc.)
    return _extractTextFrom(element);
  }

  static bool? _getCheckboxState(String key) {
    final element = _findElementByKey(key);
    if (element == null) return null;

    final widget = element.widget;
    if (widget is Checkbox) {
      return widget.value;
    }
    if (widget is Switch) {
      return widget.value;
    }
    return null;
  }

  static double? _getSliderValue(String key) {
    final element = _findElementByKey(key);
    if (element == null) return null;

    final widget = element.widget;
    if (widget is Slider) {
      return widget.value;
    }
    return null;
  }

  static Future<bool> _waitForElement(
      {String? key, String? text, int timeout = 5000}) async {
    final endTime = DateTime.now().add(Duration(milliseconds: timeout));

    while (DateTime.now().isBefore(endTime)) {
      final element = _findElement(key: key, text: text);
      if (element != null) return true;
      await Future.delayed(const Duration(milliseconds: 100));
    }

    return false;
  }

  static Future<bool> _waitForGone(
      {String? key, String? text, int timeout = 5000}) async {
    final endTime = DateTime.now().add(Duration(milliseconds: timeout));

    while (DateTime.now().isBefore(endTime)) {
      final element = _findElement(key: key, text: text);
      if (element == null) return true;
      await Future.delayed(const Duration(milliseconds: 100));
    }

    return false;
  }

  // ==================== SCREENSHOT ====================

  /// Captures the full composited scene from the RenderView's layer.
  /// This correctly captures the current visible page even after navigation,
  /// avoiding the bug where DFS finds a RepaintBoundary from an old route.
  /// Returns the image in logical pixel dimensions scaled by [pixelRatio].
  static Future<ui.Image?> _captureFullScene({double pixelRatio = 1.0}) async {
    await WidgetsBinding.instance.endOfFrame;

    final binding = WidgetsBinding.instance;
    // ignore: invalid_use_of_protected_member
    final renderObject = binding.rootElement?.renderObject;
    if (renderObject == null) return null;

    // Walk up to the RenderView (root of the render tree).
    // RenderView's layer contains ALL Navigator routes composited together.
    RenderObject root = renderObject;
    while (root.parent != null) {
      root = root.parent!;
    }

    // ignore: invalid_use_of_protected_member
    final layer = root.layer;
    if (layer is OffsetLayer) {
      // RenderView's TransformLayer includes a device-pixel-ratio scale.
      // Use physical bounds and adjust pixelRatio to produce logical-sized output.
      final view = binding.platformDispatcher.views.first;
      final physicalSize = view.physicalSize;
      final dpr = view.devicePixelRatio;
      return layer.toImage(
        Offset.zero & physicalSize,
        pixelRatio: pixelRatio / dpr,
      );
    }

    // Fallback: try a RepaintBoundary (pre-navigation or single-route apps)
    if (renderObject is RenderRepaintBoundary) {
      return renderObject.toImage(pixelRatio: pixelRatio);
    }

    RenderRepaintBoundary? boundary;
    void findBoundary(RenderObject obj) {
      if (boundary != null) return;
      if (obj is RenderRepaintBoundary) {
        boundary = obj;
        return;
      }
      obj.visitChildren(findBoundary);
    }

    renderObject.visitChildren(findBoundary);
    if (boundary == null) {
      _log('No RenderRepaintBoundary found');
      return null;
    }
    return boundary!.toImage(pixelRatio: pixelRatio);
  }

  static Future<String?> _takeScreenshot(
      {double quality = 1.0, int? maxWidth}) async {
    try {
      // Use quality as pixel ratio (lower = smaller image)
      var pixelRatio = quality.clamp(0.1, 1.0);
      var image = await _captureFullScene(pixelRatio: pixelRatio);
      if (image == null) {
        _log('Screenshot capture failed');
        return null;
      }

      // Scale down if maxWidth is specified
      if (maxWidth != null && image.width > maxWidth) {
        final scale = maxWidth / image.width;
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        final newWidth = (image.width * scale).toInt();
        final newHeight = (image.height * scale).toInt();

        canvas.drawImageRect(
          image,
          Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
          Rect.fromLTWH(0, 0, newWidth.toDouble(), newHeight.toDouble()),
          Paint()..filterQuality = FilterQuality.medium,
        );

        final picture = recorder.endRecording();
        image = await picture.toImage(newWidth, newHeight);
      }

      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return null;
      return base64Encode(byteData.buffer.asUint8List());
    } catch (e) {
      _log('Screenshot failed: $e');
      return null;
    }
  }

  static Future<String?> _takeRegionScreenshot(
      double x, double y, double width, double height) async {
    try {
      final fullImage = await _captureFullScene(pixelRatio: 1.0);
      if (fullImage == null) {
        _log('Region screenshot capture failed');
        return null;
      }

      // Crop to specified region
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);

      canvas.drawImageRect(
        fullImage,
        Rect.fromLTWH(x, y, width, height),
        Rect.fromLTWH(0, 0, width, height),
        Paint(),
      );

      final picture = recorder.endRecording();
      final croppedImage = await picture.toImage(width.toInt(), height.toInt());
      final byteData =
          await croppedImage.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return null;
      return base64Encode(byteData.buffer.asUint8List());
    } catch (e) {
      _log('Region screenshot failed: $e');
      return null;
    }
  }

  static Future<String?> _takeElementScreenshot(String key) async {
    try {
      final element = _findElementByKey(key);
      if (element == null) {
        _log('Element not found: $key');
        return null;
      }

      final renderObject = element.renderObject;
      if (renderObject == null) {
        _log('No render object for element: $key');
        return null;
      }

      // If it's a RenderRepaintBoundary, capture directly
      if (renderObject is RenderRepaintBoundary) {
        final image = await renderObject.toImage(pixelRatio: 1.0);
        final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
        if (byteData == null) return null;
        return base64Encode(byteData.buffer.asUint8List());
      }

      // For other render objects, find the nearest RepaintBoundary ancestor
      RenderObject? current = renderObject;
      while (current != null) {
        if (current is RenderRepaintBoundary) {
          // Get the element's bounds relative to the boundary
          if (renderObject is RenderBox) {
            final box = renderObject;
            final boundaryBox = current;

            // Get element position relative to boundary
            final offset =
                box.localToGlobal(Offset.zero, ancestor: boundaryBox);
            final size = box.size;

            // Capture the boundary
            final fullImage = await current.toImage(pixelRatio: 1.0);

            // Crop to element bounds
            final recorder = ui.PictureRecorder();
            final canvas = Canvas(recorder);

            // Draw the cropped portion
            canvas.drawImageRect(
              fullImage,
              Rect.fromLTWH(offset.dx, offset.dy, size.width, size.height),
              Rect.fromLTWH(0, 0, size.width, size.height),
              Paint(),
            );

            final picture = recorder.endRecording();
            final croppedImage =
                await picture.toImage(size.width.toInt(), size.height.toInt());
            final byteData =
                await croppedImage.toByteData(format: ui.ImageByteFormat.png);
            if (byteData == null) return null;
            return base64Encode(byteData.buffer.asUint8List());
          }
        }
        current = current.parent;
      }

      _log('No suitable RenderRepaintBoundary ancestor found for: $key');
      return null;
    } catch (e) {
      _log('Element screenshot failed: $e');
      return null;
    }
  }

  // ==================== NAVIGATION ====================

  static String? _getCurrentRoute() {
    String? currentRoute;
    final binding = WidgetsBinding.instance;

    void visit(Element element) {
      if (element.widget is ModalRoute) {
        final route = ModalRoute.of(element);
        if (route != null) {
          currentRoute = route.settings.name;
        }
      }
      element.visitChildren(visit);
    }

    // ignore: invalid_use_of_protected_member
    if (binding.rootElement != null) {
      visit(binding.rootElement!);
    }

    return currentRoute;
  }

  static bool _goBack() {
    final context = _findNavigatorContext();
    if (context == null) return false;

    final navigator = Navigator.of(context, rootNavigator: false);
    if (navigator.canPop()) {
      navigator.pop();
      return true;
    }
    return false;
  }

  static List<String> _getNavigationStack() {
    final routes = <String>[];
    final context = _findNavigatorContext();
    if (context == null) return routes;

    // This is a simplified version - full implementation would need NavigatorState access
    final currentRoute = _getCurrentRoute();
    if (currentRoute != null) {
      routes.add(currentRoute);
    }

    return routes;
  }

  static BuildContext? _findNavigatorContext() {
    BuildContext? context;
    final binding = WidgetsBinding.instance;

    void visit(Element element) {
      if (context != null) return;
      if (element.widget is Navigator) {
        context = element;
        return;
      }
      element.visitChildren(visit);
    }

    // ignore: invalid_use_of_protected_member
    if (binding.rootElement != null) {
      visit(binding.rootElement!);
    }

    return context;
  }

  // ==================== DEBUG & LOGS ====================

  static void _log(String message) {
    final logEntry = '[${DateTime.now().toIso8601String()}] $message';
    _logs.add(logEntry);
    print('Flutter Skill: $message');
  }

  static Map<String, dynamic> _getPerformanceMetrics() {
    return {
      'timestamp': DateTime.now().toIso8601String(),
      'logCount': _logs.length,
      'errorCount': _errors.length,
    };
  }

  // ==================== HELPERS ====================

  static String _getSwipeDirection(Offset delta) {
    if (delta.dx.abs() > delta.dy.abs()) {
      return delta.dx > 0 ? 'right' : 'left';
    } else {
      return delta.dy > 0 ? 'down' : 'up';
    }
  }

  static String? _extractTextFrom(Element element) {
    String? found;
    void visit(Element e) {
      if (found != null) return;
      if (e.widget is Text) {
        final data = (e.widget as Text).data;
        // Skip null or empty text — internal Flutter widgets (e.g. inside
        // FloatingActionButton, Tooltip) often render empty Text("") nodes.
        if (data != null && data.isNotEmpty) {
          found = data;
          return;
        }
      } else if (e.widget is RichText) {
        final plain = (e.widget as RichText).text.toPlainText();
        if (plain.isNotEmpty) {
          found = plain;
          return;
        }
      }
      e.visitChildren(visit);
    }

    visit(element);
    return found;
  }
}

// ==================== TEST INDICATORS ====================

/// Visual indicator types for test actions
enum IndicatorType { tap, swipe, longPress, textInput, hint, cursor, character }

/// Character action types for animated character
enum CharacterAction {
  tapping, // Character tapping/clicking
  typing, // Character typing
  swiping, // Character swiping gesture
  holding, // Character holding/pressing
  dragging, // Character dragging
  pointing, // Character pointing
}

/// Character state for persistent character
enum CharacterState {
  idle, // Standing still, breathing animation
  walking, // Moving to target
  acting, // Performing action
}

/// Style configuration for indicators
enum IndicatorStyle {
  minimal, // Small, fast, no hints
  standard, // Medium, normal speed, 1s hints
  detailed, // Large, slow, 2s hints + debug info
}

/// Data model for an active indicator
class IndicatorData {
  final IndicatorType type;
  final Offset? position;
  final Offset? endPosition;
  final Duration? duration;
  final Rect? bounds;
  final String? message;
  final CharacterAction? action;
  final DateTime timestamp;

  IndicatorData({
    required this.type,
    this.position,
    this.endPosition,
    this.duration,
    this.bounds,
    this.message,
    this.action,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
}

/// Manages the overlay entry and indicator display
class TestIndicatorOverlay {
  OverlayEntry? _entry;
  final GlobalKey<_TestIndicatorWidgetState> _widgetKey = GlobalKey();
  IndicatorStyle _style = IndicatorStyle.standard;

  /// Enable the indicator overlay
  void enable() {
    if (_entry != null) return;

    final overlay = _findOverlayState();
    if (overlay == null) {
      print('Flutter Skill: Cannot find Overlay to show indicators');
      return;
    }

    _entry = OverlayEntry(
      builder: (context) => _TestIndicatorWidget(
        key: _widgetKey,
        style: _style,
      ),
    );

    overlay.insert(_entry!);
    print('Flutter Skill: Test indicators enabled');
  }

  /// Disable and remove the indicator overlay
  void disable() {
    _entry?.remove();
    _entry = null;
    print('Flutter Skill: Test indicators disabled');
  }

  /// Set indicator style
  void setStyle(IndicatorStyle style) {
    _style = style;
    _widgetKey.currentState?.setStyle(style);
  }

  /// Show tap indicator
  void showTap(Offset position, {String? hint}) {
    _widgetKey.currentState?.addIndicator(IndicatorData(
      type: IndicatorType.tap,
      position: position,
      message: hint,
    ));
  }

  /// Show swipe indicator
  void showSwipe(Offset start, Offset end, {String? hint}) {
    _widgetKey.currentState?.addIndicator(IndicatorData(
      type: IndicatorType.swipe,
      position: start,
      endPosition: end,
      message: hint,
    ));
  }

  /// Show long press indicator
  void showLongPress(Offset position, Duration duration, {String? hint}) {
    _widgetKey.currentState?.addIndicator(IndicatorData(
      type: IndicatorType.longPress,
      position: position,
      duration: duration,
      message: hint,
    ));
  }

  /// Show text input indicator
  void showTextInput(Rect bounds, {String? hint}) {
    _widgetKey.currentState?.addIndicator(IndicatorData(
      type: IndicatorType.textInput,
      bounds: bounds,
      message: hint,
    ));
  }

  /// Show action hint only
  void showHint(String message) {
    _widgetKey.currentState?.addIndicator(IndicatorData(
      type: IndicatorType.hint,
      message: message,
    ));
  }

  /// Show cursor/pointer indicator at position
  void showCursor(Offset position, {String? hint}) {
    _widgetKey.currentState?.addIndicator(IndicatorData(
      type: IndicatorType.cursor,
      position: position,
      message: hint,
    ));
  }

  /// Show animated character with action
  void showCharacter(Offset position, CharacterAction action,
      {String? hint, Offset? endPosition}) {
    _widgetKey.currentState?.addIndicator(IndicatorData(
      type: IndicatorType.character,
      position: position,
      endPosition: endPosition,
      action: action,
      message: hint,
    ));
  }

  /// Find the app's overlay state
  OverlayState? _findOverlayState() {
    final context = WidgetsBinding.instance.rootElement;
    if (context == null) return null;

    OverlayState? overlayState;

    void visit(Element element) {
      if (overlayState != null) return;
      if (element.widget is Overlay) {
        overlayState = (element as StatefulElement).state as OverlayState;
        return;
      }
      element.visitChildren(visit);
    }

    visit(context);
    return overlayState;
  }
}

/// Widget that renders all test indicators
class _TestIndicatorWidget extends StatefulWidget {
  final IndicatorStyle style;

  const _TestIndicatorWidget({super.key, required this.style});

  @override
  State<_TestIndicatorWidget> createState() => _TestIndicatorWidgetState();
}

class _TestIndicatorWidgetState extends State<_TestIndicatorWidget>
    with TickerProviderStateMixin {
  final List<IndicatorData> _indicators = [];
  final Map<IndicatorData, AnimationController> _controllers = {};
  IndicatorStyle _style = IndicatorStyle.standard;

  @override
  void initState() {
    super.initState();
    _style = widget.style;
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void setStyle(IndicatorStyle style) {
    setState(() {
      _style = style;
    });
  }

  void addIndicator(IndicatorData indicator) {
    setState(() {
      // If adding a character indicator, remove any existing character indicators first
      // This ensures only one character is visible at a time
      if (indicator.type == IndicatorType.character) {
        final existingCharacters = _indicators
            .where((i) => i.type == IndicatorType.character)
            .toList();

        for (final existing in existingCharacters) {
          _indicators.remove(existing);
          _controllers[existing]?.dispose();
          _controllers.remove(existing);
        }
      }

      _indicators.add(indicator);

      // Create animation controller
      final duration = _getAnimationDuration(indicator);
      final controller = AnimationController(
        vsync: this,
        duration: duration,
      );

      _controllers[indicator] = controller;

      // Start animation
      controller.forward().then((_) {
        // Remove after animation completes
        Future.delayed(const Duration(milliseconds: 100), () {
          if (mounted) {
            setState(() {
              _indicators.remove(indicator);
              _controllers[indicator]?.dispose();
              _controllers.remove(indicator);
            });
          }
        });
      });
    });
  }

  Duration _getAnimationDuration(IndicatorData indicator) {
    switch (_style) {
      case IndicatorStyle.minimal:
        return const Duration(milliseconds: 200);
      case IndicatorStyle.standard:
        return indicator.type == IndicatorType.longPress &&
                indicator.duration != null
            ? indicator.duration!
            : const Duration(milliseconds: 500);
      case IndicatorStyle.detailed:
        return indicator.type == IndicatorType.longPress &&
                indicator.duration != null
            ? indicator.duration!
            : indicator.type == IndicatorType.character
                ? const Duration(
                    milliseconds:
                        10000) // 10 seconds - persistent walking character
                : const Duration(milliseconds: 800);
    }
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Stack(
        children: [
          // Render each indicator
          for (final indicator in _indicators)
            _buildIndicator(context, indicator),

          // Render action hints at the top
          if (_style != IndicatorStyle.minimal) ..._buildActionHints(context),
        ],
      ),
    );
  }

  Widget _buildIndicator(BuildContext context, IndicatorData indicator) {
    final controller = _controllers[indicator];
    if (controller == null) return const SizedBox.shrink();

    switch (indicator.type) {
      case IndicatorType.tap:
        return _TapIndicator(
          position: indicator.position!,
          animation: controller,
          style: _style,
        );

      case IndicatorType.swipe:
        return _SwipeIndicator(
          start: indicator.position!,
          end: indicator.endPosition!,
          animation: controller,
          style: _style,
        );

      case IndicatorType.longPress:
        return _LongPressIndicator(
          position: indicator.position!,
          animation: controller,
          style: _style,
        );

      case IndicatorType.textInput:
        return _TextInputIndicator(
          bounds: indicator.bounds!,
          animation: controller,
          style: _style,
        );

      case IndicatorType.cursor:
        return _CursorIndicator(
          position: indicator.position!,
          animation: controller,
          style: _style,
        );

      case IndicatorType.character:
        return _AnimatedCharacterIndicator(
          position: indicator.position!,
          endPosition: indicator.endPosition,
          action: indicator.action ?? CharacterAction.pointing,
          animation: controller,
          style: _style,
        );

      case IndicatorType.hint:
        return const SizedBox.shrink();
    }
  }

  List<Widget> _buildActionHints(BuildContext context) {
    final hints = _indicators
        .where((i) => i.message != null && i.message!.isNotEmpty)
        .toList();

    if (hints.isEmpty) return [];

    // Show only the most recent hint
    final latestHint = hints.last;
    final controller = _controllers[latestHint];
    if (controller == null) return [];

    return [
      Positioned(
        top: MediaQuery.of(context).padding.top + 8,
        left: 16,
        right: 16,
        child: _ActionHint(
          message: latestHint.message!,
          animation: controller,
          style: _style,
        ),
      ),
    ];
  }
}

// ==================== INDICATOR WIDGETS ====================

/// Tap indicator: expanding circle
class _TapIndicator extends StatelessWidget {
  final Offset position;
  final Animation<double> animation;
  final IndicatorStyle style;

  const _TapIndicator({
    required this.position,
    required this.animation,
    required this.style,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        final size = _getSize();
        final radius = size * animation.value;
        final opacity = (1.0 - animation.value) * 0.5;

        return Positioned(
          left: position.dx - radius,
          top: position.dy - radius,
          child: Container(
            width: radius * 2,
            height: radius * 2,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: const Color(0xFF4CAF50).withOpacity(opacity),
                width: 3,
              ),
              color: const Color(0xFF4CAF50).withOpacity(opacity * 0.3),
            ),
          ),
        );
      },
    );
  }

  double _getSize() {
    switch (style) {
      case IndicatorStyle.minimal:
        return 30;
      case IndicatorStyle.standard:
        return 50;
      case IndicatorStyle.detailed:
        return 70;
    }
  }
}

/// Swipe indicator: arrow with trail
class _SwipeIndicator extends StatelessWidget {
  final Offset start;
  final Offset end;
  final Animation<double> animation;
  final IndicatorStyle style;

  const _SwipeIndicator({
    required this.start,
    required this.end,
    required this.animation,
    required this.style,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        return CustomPaint(
          painter: _SwipePainter(
            start: start,
            end: end,
            progress: animation.value,
            style: style,
          ),
          child: Container(),
        );
      },
    );
  }
}

class _SwipePainter extends CustomPainter {
  final Offset start;
  final Offset end;
  final double progress;
  final IndicatorStyle style;

  _SwipePainter({
    required this.start,
    required this.end,
    required this.progress,
    required this.style,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF9C27B0).withOpacity((1.0 - progress) * 0.5)
      ..strokeWidth = style == IndicatorStyle.minimal ? 2 : 3
      ..style = PaintingStyle.stroke;

    // Draw dashed line
    final path = Path();
    path.moveTo(start.dx, start.dy);
    path.lineTo(end.dx, end.dy);

    canvas.drawPath(
      _createDashedPath(path, dashWidth: 10, dashSpace: 5),
      paint,
    );

    // Draw arrow head
    final angle = (end - start).direction;
    final arrowSize = style == IndicatorStyle.minimal ? 15.0 : 20.0;

    final arrowPath = Path();
    arrowPath.moveTo(end.dx, end.dy);
    arrowPath.lineTo(
      end.dx - arrowSize * cos(angle - pi / 6),
      end.dy - arrowSize * sin(angle - pi / 6),
    );
    arrowPath.moveTo(end.dx, end.dy);
    arrowPath.lineTo(
      end.dx - arrowSize * cos(angle + pi / 6),
      end.dy - arrowSize * sin(angle + pi / 6),
    );

    paint.style = PaintingStyle.stroke;
    canvas.drawPath(arrowPath, paint);
  }

  Path _createDashedPath(Path source,
      {required double dashWidth, required double dashSpace}) {
    final path = Path();
    for (final metric in source.computeMetrics()) {
      double distance = 0;
      bool draw = true;
      while (distance < metric.length) {
        final length = draw ? dashWidth : dashSpace;
        if (distance + length > metric.length) {
          if (draw) {
            path.addPath(
              metric.extractPath(distance, metric.length),
              Offset.zero,
            );
          }
          break;
        }
        if (draw) {
          path.addPath(
            metric.extractPath(distance, distance + length),
            Offset.zero,
          );
        }
        distance += length;
        draw = !draw;
      }
    }
    return path;
  }

  @override
  bool shouldRepaint(_SwipePainter oldDelegate) =>
      progress != oldDelegate.progress;
}

/// Long press indicator: filling circle
class _LongPressIndicator extends StatelessWidget {
  final Offset position;
  final Animation<double> animation;
  final IndicatorStyle style;

  const _LongPressIndicator({
    required this.position,
    required this.animation,
    required this.style,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        final size = _getSize();
        final opacity = 0.5;

        return Positioned(
          left: position.dx - size,
          top: position.dy - size,
          child: SizedBox(
            width: size * 2,
            height: size * 2,
            child: CustomPaint(
              painter: _LongPressPainter(
                progress: animation.value,
                opacity: opacity,
              ),
            ),
          ),
        );
      },
    );
  }

  double _getSize() {
    switch (style) {
      case IndicatorStyle.minimal:
        return 25;
      case IndicatorStyle.standard:
        return 35;
      case IndicatorStyle.detailed:
        return 45;
    }
  }
}

class _LongPressPainter extends CustomPainter {
  final double progress;
  final double opacity;

  _LongPressPainter({required this.progress, required this.opacity});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;

    // Background circle
    final bgPaint = Paint()
      ..color = const Color(0xFFFF9800).withOpacity(opacity * 0.2)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, radius, bgPaint);

    // Progress arc
    final progressPaint = Paint()
      ..color = const Color(0xFFFF9800).withOpacity(opacity)
      ..strokeWidth = 4
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius - 2),
      -pi / 2,
      2 * pi * progress,
      false,
      progressPaint,
    );
  }

  @override
  bool shouldRepaint(_LongPressPainter oldDelegate) =>
      progress != oldDelegate.progress;
}

/// Text input indicator: glowing border
class _TextInputIndicator extends StatelessWidget {
  final Rect bounds;
  final Animation<double> animation;
  final IndicatorStyle style;

  const _TextInputIndicator({
    required this.bounds,
    required this.animation,
    required this.style,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        final opacity = (sin(animation.value * pi * 4) + 1) / 2 * 0.5;

        return Positioned(
          left: bounds.left,
          top: bounds.top,
          child: Container(
            width: bounds.width,
            height: bounds.height,
            decoration: BoxDecoration(
              border: Border.all(
                color: const Color(0xFF4CAF50).withOpacity(opacity),
                width: 2,
              ),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        );
      },
    );
  }
}

/// Cursor indicator: mouse pointer/hand icon
class _CursorIndicator extends StatelessWidget {
  final Offset position;
  final Animation<double> animation;
  final IndicatorStyle style;

  const _CursorIndicator({
    required this.position,
    required this.animation,
    required this.style,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        // Fade in quickly, stay visible, then fade out
        final opacity = animation.value < 0.1
            ? animation.value / 0.1
            : animation.value > 0.9
                ? (1.0 - animation.value) / 0.1
                : 1.0;

        // Slight bounce effect
        final scale = 1.0 + (sin(animation.value * pi * 2) * 0.1);

        return Positioned(
          left: position.dx,
          top: position.dy,
          child: Transform.scale(
            scale: scale,
            child: Opacity(
              opacity: opacity,
              child: CustomPaint(
                size: Size(
                  style == IndicatorStyle.minimal
                      ? 24
                      : style == IndicatorStyle.standard
                          ? 32
                          : 40,
                  style == IndicatorStyle.minimal
                      ? 24
                      : style == IndicatorStyle.standard
                          ? 32
                          : 40,
                ),
                painter: _CursorPainter(style: style),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Custom painter for cursor/pointer icon
class _CursorPainter extends CustomPainter {
  final IndicatorStyle style;

  _CursorPainter({required this.style});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF2196F3)
      ..style = PaintingStyle.fill;

    final strokePaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    // Draw hand/pointer cursor shape
    final path = Path();

    // Pointer arrow shape
    path.moveTo(size.width * 0.2, size.height * 0.2);
    path.lineTo(size.width * 0.2, size.height * 0.7);
    path.lineTo(size.width * 0.35, size.height * 0.6);
    path.lineTo(size.width * 0.5, size.height * 0.8);
    path.lineTo(size.width * 0.6, size.height * 0.75);
    path.lineTo(size.width * 0.45, size.height * 0.55);
    path.lineTo(size.width * 0.7, size.height * 0.5);
    path.close();

    // Draw shadow/outline
    canvas.drawPath(path, strokePaint);
    // Draw main cursor
    canvas.drawPath(path, paint);

    // Add small circle at tip for emphasis
    final tipPaint = Paint()
      ..color = const Color(0xFFFFEB3B)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(
      Offset(size.width * 0.2, size.height * 0.2),
      size.width * 0.08,
      tipPaint,
    );
  }

  @override
  bool shouldRepaint(_CursorPainter oldDelegate) => false;
}

/// Animated character indicator: game-like character with particle effects
class _AnimatedCharacterIndicator extends StatelessWidget {
  final Offset position;
  final Offset? endPosition;
  final CharacterAction action;
  final Animation<double> animation;
  final IndicatorStyle style;

  const _AnimatedCharacterIndicator({
    required this.position,
    this.endPosition,
    required this.action,
    required this.animation,
    required this.style,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        // Smooth movement using game-like easing curves
        // Phase 1 (0-0.3): Walking to target with elastic easing
        // Phase 2 (0.3-0.6): Performing action with anticipation
        // Phase 3 (0.6-1.0): Idle with gentle breathing

        double walkProgress;
        if (animation.value < 0.3) {
          // Walking phase - use elastic easing for bouncy movement
          walkProgress = Curves.easeOutCubic.transform(animation.value / 0.3);
        } else {
          walkProgress = 1.0;
        }

        final currentPos = endPosition != null
            ? Offset.lerp(position, endPosition, walkProgress)!
            : position;

        // Enhanced fade with glow effect
        final opacity = animation.value < 0.03
            ? animation.value / 0.03
            : animation.value > 0.97
                ? (1.0 - animation.value) / 0.03
                : 1.0;

        // Determine current state based on animation progress
        CharacterState currentState;
        double actionProgress;

        if (animation.value < 0.3) {
          // Walking phase
          currentState = CharacterState.walking;
          actionProgress = animation.value / 0.3;
        } else if (animation.value < 0.6) {
          // Action phase - with anticipation and impact
          currentState = CharacterState.acting;
          actionProgress =
              Curves.easeOutBack.transform((animation.value - 0.3) / 0.3);
        } else {
          // Idle phase - gentle breathing animation
          currentState = CharacterState.idle;
          actionProgress = (animation.value - 0.6) / 0.4;
        }

        return Positioned(
          left: currentPos.dx - 40,
          top: currentPos.dy - 80,
          child: Opacity(
            opacity: opacity,
            child: Stack(
              children: [
                // Particle effects layer
                CustomPaint(
                  size: const Size(80, 80),
                  painter: _ParticleEffectPainter(
                    action: action,
                    progress: actionProgress,
                    state: currentState,
                    globalProgress: animation.value,
                  ),
                ),
                // Character layer with shadow
                CustomPaint(
                  size: const Size(80, 80),
                  painter: _GameCharacterPainter(
                    action: action,
                    progress: actionProgress,
                    state: currentState,
                    style: style,
                    globalProgress: animation.value,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Particle effect painter for game-like visual effects
class _ParticleEffectPainter extends CustomPainter {
  final CharacterAction action;
  final double progress;
  final CharacterState state;
  final double globalProgress;

  _ParticleEffectPainter({
    required this.action,
    required this.progress,
    required this.state,
    required this.globalProgress,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;

    // Draw particles based on state and action
    if (state == CharacterState.walking) {
      _drawWalkingDust(canvas, cx, cy);
    } else if (state == CharacterState.acting) {
      _drawActionParticles(canvas, cx, cy);
    }
  }

  void _drawWalkingDust(Canvas canvas, double cx, double cy) {
    final dustPaint = Paint()
      ..color = Colors.grey.withOpacity(0.3 * (1 - progress))
      ..style = PaintingStyle.fill;

    // Dust clouds behind character
    for (var i = 0; i < 3; i++) {
      final offset = i * 8.0;
      final size = 4.0 - i;
      canvas.drawCircle(
        Offset(cx - offset, cy + 30 + i * 2),
        size * (1 - progress),
        dustPaint,
      );
    }
  }

  void _drawActionParticles(Canvas canvas, double cx, double cy) {
    final particlePaint = Paint()
      ..style = PaintingStyle.fill
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2);

    // Sparkle particles during action
    for (var i = 0; i < 6; i++) {
      final angle = (i / 6) * 2 * pi + progress * pi;
      final distance = 20 + progress * 15;
      final x = cx + cos(angle) * distance;
      final y = cy + sin(angle) * distance;

      // Color gradient from yellow to orange
      final color = Color.lerp(
        const Color(0xFFFFEB3B),
        const Color(0xFFFF5722),
        i / 6,
      )!
          .withOpacity(0.8 * (1 - progress));

      particlePaint.color = color;
      canvas.drawCircle(Offset(x, y), 3 * (1 - progress), particlePaint);
    }

    // Impact effect for tapping
    if (action == CharacterAction.tapping && progress > 0.5) {
      final impactProgress = (progress - 0.5) * 2;
      final impactPaint = Paint()
        ..color =
            const Color(0xFFFF5722).withOpacity(0.5 * (1 - impactProgress))
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3;

      canvas.drawCircle(
        Offset(cx + 20, cy),
        10 + impactProgress * 15,
        impactPaint,
      );
    }
  }

  @override
  bool shouldRepaint(_ParticleEffectPainter oldDelegate) => true;
}

/// Game-like character painter with shadows and smooth animations
class _GameCharacterPainter extends CustomPainter {
  final CharacterAction action;
  final double progress;
  final IndicatorStyle style;
  final CharacterState state;
  final double globalProgress;

  _GameCharacterPainter({
    required this.action,
    required this.progress,
    required this.style,
    required this.state,
    required this.globalProgress,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final centerX = size.width / 2;
    final centerY = size.height / 2;

    // Draw shadow first (for depth)
    final shadowPaint = Paint()
      ..color = Colors.black.withOpacity(0.3)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);

    // Elliptical shadow on ground
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(centerX, centerY + 35),
        width: 30,
        height: 8,
      ),
      shadowPaint,
    );

    // Game-like character colors with gradients
    final bodyPaint = Paint()
      ..color = const Color(0xFF4CAF50)
      ..style = PaintingStyle.stroke
      ..strokeWidth = style == IndicatorStyle.minimal ? 4 : 5
      ..strokeCap = StrokeCap.round;

    final headPaint = Paint()
      ..color = const Color(0xFFFFEB3B)
      ..style = PaintingStyle.fill;

    // Head glow effect
    final glowPaint = Paint()
      ..color = const Color(0xFFFFEB3B).withOpacity(0.3)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);

    final accentPaint = Paint()
      ..color = const Color(0xFFFF5722)
      ..style = PaintingStyle.fill;

    // Breathing animation in idle state
    final breatheOffset =
        state == CharacterState.idle ? sin(globalProgress * pi * 3) * 1.5 : 0.0;

    // Draw glow around head for added depth
    if (style != IndicatorStyle.minimal) {
      canvas.drawCircle(
        Offset(centerX, centerY - 15 + breatheOffset),
        12,
        glowPaint,
      );
    }

    // Draw based on current state
    switch (state) {
      case CharacterState.walking:
        _drawWalkingCharacter(
            canvas, size, centerX, centerY, bodyPaint, headPaint, accentPaint);
        break;
      case CharacterState.acting:
        // Draw action-specific animation
        switch (action) {
          case CharacterAction.tapping:
            _drawTappingCharacter(canvas, size, centerX, centerY, bodyPaint,
                headPaint, accentPaint);
            break;
          case CharacterAction.typing:
            _drawTypingCharacter(canvas, size, centerX, centerY, bodyPaint,
                headPaint, accentPaint);
            break;
          case CharacterAction.swiping:
            _drawSwipingCharacter(canvas, size, centerX, centerY, bodyPaint,
                headPaint, accentPaint);
            break;
          case CharacterAction.holding:
            _drawHoldingCharacter(canvas, size, centerX, centerY, bodyPaint,
                headPaint, accentPaint);
            break;
          case CharacterAction.dragging:
            _drawDraggingCharacter(canvas, size, centerX, centerY, bodyPaint,
                headPaint, accentPaint);
            break;
          case CharacterAction.pointing:
            _drawPointingCharacter(canvas, size, centerX, centerY, bodyPaint,
                headPaint, accentPaint);
            break;
        }
        break;
      case CharacterState.idle:
        _drawIdleCharacter(
            canvas, size, centerX, centerY, bodyPaint, headPaint, accentPaint);
        break;
    }
  }

  void _drawTappingCharacter(Canvas canvas, Size size, double cx, double cy,
      Paint body, Paint head, Paint accent) {
    // Animated bounce effect
    final bounce = sin(progress * pi * 4) * 3;

    // Head
    canvas.drawCircle(Offset(cx, cy - 15 + bounce), 8, head);

    // Eyes
    final eyePaint = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(cx - 3, cy - 16 + bounce), 1.5, eyePaint);
    canvas.drawCircle(Offset(cx + 3, cy - 16 + bounce), 1.5, eyePaint);

    // Body
    canvas.drawLine(
      Offset(cx, cy - 7 + bounce),
      Offset(cx, cy + 10 + bounce),
      body,
    );

    // Arms - tapping motion
    final armAngle = sin(progress * pi * 8) * 0.3;
    canvas.drawLine(
      Offset(cx, cy),
      Offset(cx - 12, cy + 8 + bounce + armAngle * 5),
      body,
    );
    canvas.drawLine(
      Offset(cx, cy),
      Offset(cx + 12, cy + 8 + bounce - armAngle * 5),
      body,
    );

    // Tapping indicator (finger point)
    canvas.drawCircle(
        Offset(cx + 12, cy + 8 + bounce - armAngle * 5), 3, accent);

    // Legs
    canvas.drawLine(
      Offset(cx, cy + 10 + bounce),
      Offset(cx - 8, cy + 22 + bounce),
      body,
    );
    canvas.drawLine(
      Offset(cx, cy + 10 + bounce),
      Offset(cx + 8, cy + 22 + bounce),
      body,
    );
  }

  void _drawTypingCharacter(Canvas canvas, Size size, double cx, double cy,
      Paint body, Paint head, Paint accent) {
    // Head
    canvas.drawCircle(Offset(cx, cy - 12), 8, head);

    // Eyes looking down
    final eyePaint = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(cx - 3, cy - 10), 1.5, eyePaint);
    canvas.drawCircle(Offset(cx + 3, cy - 10), 1.5, eyePaint);

    // Body
    canvas.drawLine(
      Offset(cx, cy - 4),
      Offset(cx, cy + 12),
      body,
    );

    // Arms - typing motion
    final armWave = sin(progress * pi * 12) * 3;
    canvas.drawLine(
      Offset(cx, cy + 2),
      Offset(cx - 10, cy + 14 + armWave),
      body,
    );
    canvas.drawLine(
      Offset(cx, cy + 2),
      Offset(cx + 10, cy + 14 - armWave),
      body,
    );

    // Keyboard representation
    final keyboardPaint = Paint()
      ..color = const Color(0xFF9E9E9E)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawRect(
      Rect.fromCenter(center: Offset(cx, cy + 22), width: 24, height: 4),
      keyboardPaint,
    );

    // Typing indicators (small dots)
    canvas.drawCircle(Offset(cx - 6 + armWave, cy + 14 + armWave), 2, accent);
    canvas.drawCircle(Offset(cx + 6 - armWave, cy + 14 - armWave), 2, accent);

    // Legs
    canvas.drawLine(
      Offset(cx, cy + 12),
      Offset(cx - 6, cy + 20),
      body,
    );
    canvas.drawLine(
      Offset(cx, cy + 12),
      Offset(cx + 6, cy + 20),
      body,
    );
  }

  void _drawSwipingCharacter(Canvas canvas, Size size, double cx, double cy,
      Paint body, Paint head, Paint accent) {
    // Leaning forward with swipe motion
    final swipeAngle = progress * pi * 2;
    final armX = cos(swipeAngle) * 15;
    final armY = sin(swipeAngle) * 8;

    // Head
    canvas.drawCircle(Offset(cx + armX * 0.3, cy - 12), 8, head);

    // Eyes
    final eyePaint = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(cx + armX * 0.3 - 3, cy - 13), 1.5, eyePaint);
    canvas.drawCircle(Offset(cx + armX * 0.3 + 3, cy - 13), 1.5, eyePaint);

    // Body leaning
    canvas.drawLine(
      Offset(cx + armX * 0.3, cy - 4),
      Offset(cx, cy + 10),
      body,
    );

    // Swiping arm
    canvas.drawLine(
      Offset(cx, cy),
      Offset(cx + armX, cy + armY),
      body,
    );

    // Swipe trail
    final trailPaint = Paint()
      ..color = const Color(0xFF9C27B0).withOpacity(0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    canvas.drawLine(
      Offset(cx + armX - 10, cy + armY),
      Offset(cx + armX + 10, cy + armY),
      trailPaint,
    );

    // Hand indicator
    canvas.drawCircle(Offset(cx + armX, cy + armY), 3, accent);

    // Other arm
    canvas.drawLine(
      Offset(cx, cy),
      Offset(cx - 10, cy + 8),
      body,
    );

    // Legs
    canvas.drawLine(
      Offset(cx, cy + 10),
      Offset(cx - 8, cy + 22),
      body,
    );
    canvas.drawLine(
      Offset(cx, cy + 10),
      Offset(cx + 8, cy + 22),
      body,
    );
  }

  void _drawHoldingCharacter(Canvas canvas, Size size, double cx, double cy,
      Paint body, Paint head, Paint accent) {
    // Concentrated holding pose
    final pulse = 1.0 + sin(progress * pi * 6) * 0.1;

    // Head
    canvas.drawCircle(Offset(cx, cy - 12), 8 * pulse, head);

    // Focused eyes
    final eyePaint = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(cx - 3, cy - 13), 2, eyePaint);
    canvas.drawCircle(Offset(cx + 3, cy - 13), 2, eyePaint);

    // Body
    canvas.drawLine(
      Offset(cx, cy - 4),
      Offset(cx, cy + 10),
      body,
    );

    // Arms holding/pressing
    canvas.drawLine(
      Offset(cx, cy),
      Offset(cx - 10, cy + 10),
      body,
    );
    canvas.drawLine(
      Offset(cx, cy),
      Offset(cx + 10, cy + 10),
      body,
    );

    // Pressure indicator
    canvas.drawCircle(Offset(cx, cy + 14), 6 * pulse, accent);

    // Legs
    canvas.drawLine(
      Offset(cx, cy + 10),
      Offset(cx - 6, cy + 20),
      body,
    );
    canvas.drawLine(
      Offset(cx, cy + 10),
      Offset(cx + 6, cy + 20),
      body,
    );
  }

  void _drawDraggingCharacter(Canvas canvas, Size size, double cx, double cy,
      Paint body, Paint head, Paint accent) {
    // Pulling/dragging motion
    final dragX = sin(progress * pi) * 5;

    // Head
    canvas.drawCircle(Offset(cx - dragX, cy - 12), 8, head);

    // Determined eyes
    final eyePaint = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(cx - dragX - 3, cy - 13), 1.5, eyePaint);
    canvas.drawCircle(Offset(cx - dragX + 3, cy - 13), 1.5, eyePaint);

    // Body leaning back
    canvas.drawLine(
      Offset(cx - dragX, cy - 4),
      Offset(cx, cy + 10),
      body,
    );

    // Arms pulling
    canvas.drawLine(
      Offset(cx, cy),
      Offset(cx + 12 + dragX, cy + 2),
      body,
    );
    canvas.drawLine(
      Offset(cx, cy + 4),
      Offset(cx + 12 + dragX, cy + 6),
      body,
    );

    // Object being dragged
    final objectPaint = Paint()
      ..color = const Color(0xFF2196F3)
      ..style = PaintingStyle.fill;
    canvas.drawRect(
      Rect.fromCenter(
        center: Offset(cx + 16 + dragX, cy + 4),
        width: 8,
        height: 8,
      ),
      objectPaint,
    );

    // Drag trail
    final trailPaint = Paint()
      ..color = const Color(0xFF9C27B0).withOpacity(0.3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(cx + 20 + dragX, cy + 4),
      Offset(cx + 28, cy + 4),
      trailPaint,
    );

    // Legs bracing
    canvas.drawLine(
      Offset(cx, cy + 10),
      Offset(cx - 10, cy + 22),
      body,
    );
    canvas.drawLine(
      Offset(cx, cy + 10),
      Offset(cx + 6, cy + 22),
      body,
    );
  }

  void _drawPointingCharacter(Canvas canvas, Size size, double cx, double cy,
      Paint body, Paint head, Paint accent) {
    // Simple pointing pose
    // Head
    canvas.drawCircle(Offset(cx, cy - 12), 8, head);

    // Eyes
    final eyePaint = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(cx - 3, cy - 13), 1.5, eyePaint);
    canvas.drawCircle(Offset(cx + 3, cy - 13), 1.5, eyePaint);

    // Smile
    final smilePaint = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final smilePath = Path();
    smilePath.moveTo(cx - 3, cy - 10);
    smilePath.quadraticBezierTo(cx, cy - 8, cx + 3, cy - 10);
    canvas.drawPath(smilePath, smilePaint);

    // Body
    canvas.drawLine(
      Offset(cx, cy - 4),
      Offset(cx, cy + 10),
      body,
    );

    // Pointing arm
    canvas.drawLine(
      Offset(cx, cy),
      Offset(cx + 14, cy + 8),
      body,
    );

    // Pointing finger
    canvas.drawCircle(Offset(cx + 14, cy + 8), 3, accent);

    // Other arm
    canvas.drawLine(
      Offset(cx, cy),
      Offset(cx - 10, cy + 6),
      body,
    );

    // Legs
    canvas.drawLine(
      Offset(cx, cy + 10),
      Offset(cx - 6, cy + 22),
      body,
    );
    canvas.drawLine(
      Offset(cx, cy + 10),
      Offset(cx + 6, cy + 22),
      body,
    );
  }

  void _drawWalkingCharacter(Canvas canvas, Size size, double cx, double cy,
      Paint body, Paint head, Paint accent) {
    // Walking animation with alternating legs
    final walkCycle =
        progress * pi * 4; // Multiple walking cycles during the walk
    final bobbing = sin(walkCycle) * 2; // Vertical bobbing motion
    final leftLegSwing = sin(walkCycle) * 12;
    final rightLegSwing = sin(walkCycle + pi) * 12;
    final armSwing = sin(walkCycle) * 8;

    // Head with bobbing
    canvas.drawCircle(Offset(cx, cy - 12 + bobbing), 8, head);

    // Eyes (determined look)
    final eyePaint = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(cx - 3, cy - 13 + bobbing), 1.5, eyePaint);
    canvas.drawCircle(Offset(cx + 3, cy - 13 + bobbing), 1.5, eyePaint);

    // Body with bobbing
    canvas.drawLine(
      Offset(cx, cy - 4 + bobbing),
      Offset(cx, cy + 10 + bobbing),
      body,
    );

    // Arms swinging
    canvas.drawLine(
      Offset(cx, cy + bobbing),
      Offset(cx - 10 + armSwing, cy + 8 + bobbing),
      body,
    );
    canvas.drawLine(
      Offset(cx, cy + bobbing),
      Offset(cx + 10 - armSwing, cy + 8 + bobbing),
      body,
    );

    // Legs alternating (walking motion)
    canvas.drawLine(
      Offset(cx, cy + 10 + bobbing),
      Offset(cx - 6 + leftLegSwing * 0.5, cy + 22),
      body,
    );
    canvas.drawLine(
      Offset(cx, cy + 10 + bobbing),
      Offset(cx + 6 + rightLegSwing * 0.5, cy + 22),
      body,
    );

    // Walking dust/motion lines for extra effect
    if (style == IndicatorStyle.detailed) {
      final dustPaint = Paint()
        ..color = const Color(0xFF9E9E9E).withOpacity(0.4)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round;

      // Small motion lines behind character
      canvas.drawLine(
        Offset(cx - 8, cy + 20),
        Offset(cx - 12, cy + 22),
        dustPaint,
      );
      canvas.drawLine(
        Offset(cx - 6, cy + 18),
        Offset(cx - 10, cy + 20),
        dustPaint,
      );
    }
  }

  void _drawIdleCharacter(Canvas canvas, Size size, double cx, double cy,
      Paint body, Paint head, Paint accent) {
    // Idle animation with subtle breathing
    final breathing = sin(progress * pi * 2) * 1.5; // Slow breathing motion
    final blink =
        (progress * 20) % 1.0 > 0.9 ? 0.5 : 1.5; // Occasional blinking

    // Head with subtle breathing
    canvas.drawCircle(Offset(cx, cy - 12 + breathing * 0.3), 8, head);

    // Eyes (blinking)
    final eyePaint = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.fill;
    canvas.drawCircle(
        Offset(cx - 3, cy - 13 + breathing * 0.3), blink, eyePaint);
    canvas.drawCircle(
        Offset(cx + 3, cy - 13 + breathing * 0.3), blink, eyePaint);

    // Smile
    final smilePaint = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final smilePath = Path();
    smilePath.moveTo(cx - 3, cy - 10 + breathing * 0.3);
    smilePath.quadraticBezierTo(
        cx, cy - 8 + breathing * 0.3, cx + 3, cy - 10 + breathing * 0.3);
    canvas.drawPath(smilePath, smilePaint);

    // Body with breathing
    canvas.drawLine(
      Offset(cx, cy - 4 + breathing * 0.3),
      Offset(cx, cy + 10 + breathing),
      body,
    );

    // Arms relaxed at sides
    canvas.drawLine(
      Offset(cx, cy + breathing * 0.5),
      Offset(cx - 8, cy + 10 + breathing),
      body,
    );
    canvas.drawLine(
      Offset(cx, cy + breathing * 0.5),
      Offset(cx + 8, cy + 10 + breathing),
      body,
    );

    // Legs standing still
    canvas.drawLine(
      Offset(cx, cy + 10 + breathing),
      Offset(cx - 6, cy + 22),
      body,
    );
    canvas.drawLine(
      Offset(cx, cy + 10 + breathing),
      Offset(cx + 6, cy + 22),
      body,
    );
  }

  @override
  bool shouldRepaint(_GameCharacterPainter oldDelegate) =>
      progress != oldDelegate.progress ||
      action != oldDelegate.action ||
      state != oldDelegate.state ||
      globalProgress != oldDelegate.globalProgress;
}

/// Action hint banner
class _ActionHint extends StatelessWidget {
  final String message;
  final Animation<double> animation;
  final IndicatorStyle style;

  const _ActionHint({
    required this.message,
    required this.animation,
    required this.style,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        // Slide in from top, then fade out
        final slideProgress =
            animation.value < 0.2 ? animation.value / 0.2 : 1.0;
        final fadeProgress =
            animation.value > 0.8 ? (1.0 - animation.value) / 0.2 : 1.0;
        final opacity = fadeProgress * 0.95;

        return Transform.translate(
          offset: Offset(0, -20 * (1 - slideProgress)),
          child: Opacity(
            opacity: opacity,
            child: Material(
              color: Colors.transparent,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.8),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: const Color(0xFF4CAF50).withOpacity(0.5),
                    width: 1,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.touch_app,
                      color: Color(0xFF4CAF50),
                      size: 16,
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        message,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
