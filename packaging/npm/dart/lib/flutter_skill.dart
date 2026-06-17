import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

/// The Binding that enables Flutter Skill automation.
class FlutterSkillBinding {
  static void ensureInitialized() {
    if (_registered) return;
    _registered = true;
    _registerExtensions();
    print('Flutter Skill Binding Initialized 🚀');
  }

  static bool _registered = false;
  static final List<String> _logs = [];
  static final List<Map<String, dynamic>> _errors = [];
  static int _pointerCounter = 1;

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

    // 2. Tap
    developer.registerExtension('ext.flutter.flutter_skill.tap',
        (method, parameters) async {
      try {
        final key = parameters['key'];
        final text = parameters['text'];
        final success = await _performTap(key: key, text: text);
        return developer.ServiceExtensionResponse.result(
          jsonEncode({
            'success': success,
            'message': success ? 'Tap successful' : 'Element not found'
          }),
        );
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
        if (text == null) {
          return developer.ServiceExtensionResponse.error(
            developer.ServiceExtensionResponse.invalidParams,
            'Missing text',
          );
        }
        final success = await _performEnterText(key: key, text: text);
        return developer.ServiceExtensionResponse.result(
          jsonEncode({
            'success': success,
            'message': success ? 'Text entered' : 'TextField not found'
          }),
        );
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
        final success = await _performScroll(key: key, text: text);
        return developer.ServiceExtensionResponse.result(
          jsonEncode({
            'success': success,
            'message': success ? 'Scroll successful' : 'Element not found'
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

    // 18. Screenshot
    developer.registerExtension('ext.flutter.flutter_skill.screenshot',
        (method, parameters) async {
      try {
        final base64Image = await _takeScreenshot();
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

  // ==================== ACTIONS ====================

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

  static Future<void> _dispatchTap(Offset position) async {
    final binding = WidgetsBinding.instance;
    final pointer = _pointerCounter++;

    binding.handlePointerEvent(
        PointerDownEvent(position: position, pointer: pointer));
    await Future.delayed(const Duration(milliseconds: 50));
    binding.handlePointerEvent(
        PointerUpEvent(position: position, pointer: pointer));
    await Future.delayed(const Duration(milliseconds: 100));
  }

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

  static Future<bool> _performScroll({String? key, String? text}) async {
    final element = _findElement(key: key, text: text);
    if (element == null) {
      _log('Element not found for scroll (key: $key, text: $text)');
      return false;
    }

    try {
      await Scrollable.ensureVisible(element,
          duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
      _log('Scrolled to element (key: $key, text: $text)');
      return true;
    } catch (e) {
      _log('Scroll failed: $e');
      return false;
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

  // ==================== UI INSPECTION ====================

  static List<Map<String, dynamic>> _findInteractiveElements() {
    final results = <Map<String, dynamic>>[];

    void visit(Element element) {
      final widget = element.widget;
      String? type;
      String? text;
      String? key;

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
      } else if (widget is GestureDetector && widget.onTap != null) {
        type = 'Tappable';
      }

      if (type != null) {
        results.add({
          if (key != null) 'key': key,
          if (text != null) 'text': text,
          'type': type,
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
          node['position'] = {'x': offset.dx, 'y': offset.dy};
          node['size'] = {
            'width': renderObject.size.width,
            'height': renderObject.size.height
          };
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

    return editableTextState?.textEditingValue.text;
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

  static Future<String?> _takeScreenshot() async {
    try {
      final binding = WidgetsBinding.instance;
      // ignore: invalid_use_of_protected_member
      final renderObject = binding.rootElement?.renderObject;
      if (renderObject is! RenderRepaintBoundary) {
        // Try to find a RenderRepaintBoundary
        RenderRepaintBoundary? boundary;
        void findBoundary(RenderObject obj) {
          if (boundary != null) return;
          if (obj is RenderRepaintBoundary) {
            boundary = obj;
            return;
          }
          obj.visitChildren(findBoundary);
        }

        renderObject?.visitChildren(findBoundary);

        if (boundary == null) {
          _log('No RenderRepaintBoundary found');
          return null;
        }

        final image = await boundary!.toImage(pixelRatio: 1.0);
        final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
        if (byteData == null) return null;
        return base64Encode(byteData.buffer.asUint8List());
      }

      final image = await renderObject.toImage(pixelRatio: 1.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return null;
      return base64Encode(byteData.buffer.asUint8List());
    } catch (e) {
      _log('Screenshot failed: $e');
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

  static String? _extractTextFrom(Element element) {
    String? found;
    void visit(Element e) {
      if (found != null) return;
      if (e.widget is Text) {
        found = (e.widget as Text).data;
      } else if (e.widget is RichText) {
        found = (e.widget as RichText).text.toPlainText();
      }
      e.visitChildren(visit);
    }

    visit(element);
    return found;
  }
}
