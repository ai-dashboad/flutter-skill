part of '../server.dart';

extension _FlutterHelpers on FlutterMcpServer {
  Future<Map<String, dynamic>> _executeBatchAssertions(
      Map<String, dynamic> args, AppDriver client) async {
    final assertions = (args['assertions'] as List<dynamic>?) ?? [];
    final results = <Map<String, dynamic>>[];
    int passed = 0, failed = 0;
    for (final assertion in assertions) {
      final a = assertion as Map<String, dynamic>;
      final aType = a['type'] as String;
      try {
        final toolName = aType == 'visible'
            ? 'assert_visible'
            : aType == 'not_visible'
                ? 'assert_not_visible'
                : aType == 'text'
                    ? 'assert_text'
                    : aType == 'element_count'
                        ? 'assert_element_count'
                        : aType;
        final toolArgs = <String, dynamic>{
          if (a['key'] != null) 'key': a['key'],
          if (a['text'] != null) 'text': a['text'],
          if (a['expected'] != null) 'expected': a['expected'],
          if (a['count'] != null) 'expected_count': a['count'],
        };
        final result = await _executeToolInner(toolName, toolArgs);
        final success = result is Map && result['success'] != false;
        if (success)
          passed++;
        else
          failed++;
        results.add({'type': aType, 'success': success, 'result': result});
      } catch (e) {
        failed++;
        results.add({'type': aType, 'success': false, 'error': e.toString()});
      }
    }
    return {
      'success': failed == 0,
      'total': assertions.length,
      'passed': passed,
      'failed': failed,
      'results': results
    };
  }

  Future<Map<String, dynamic>> _executeVisualVerify(
      Map<String, dynamic> args, AppDriver client) async {
    final quality = (args['quality'] as num?)?.toDouble() ?? 0.5;
    final desc = args['description'] as String? ?? '';
    final checkElements =
        (args['check_elements'] as List?)?.cast<String>() ?? [];

    final imageBase64 =
        await client.takeScreenshot(quality: quality, maxWidth: 800);
    String? screenshotPath;
    if (imageBase64 != null) {
      final ts = DateTime.now().millisecondsSinceEpoch;
      final file =
          File('${Directory.systemTemp.path}/flutter_skill_verify_$ts.png');
      await file.writeAsBytes(base64.decode(imageBase64));
      screenshotPath = file.path;
    }

    String snapshotText = '';
    List<String> found = [], missing = [];
    int elementCount = 0;
    try {
      final structured = await client.getInteractiveElementsStructured();
      final els = structured['elements'] as List<dynamic>? ?? [];
      elementCount = els.length;
      final buf = StringBuffer();
      for (final el in els) {
        if (el is Map<String, dynamic>) {
          buf.writeln(
              '[${el['ref'] ?? ''}] "${el['text'] ?? el['label'] ?? ''}"');
        }
      }
      snapshotText = buf.toString();
      if (checkElements.isNotEmpty) {
        final lower = snapshotText.toLowerCase();
        for (final c in checkElements) {
          (lower.contains(c.toLowerCase()) ? found : missing).add(c);
        }
      }
    } catch (e) {
      snapshotText = 'Error: $e';
    }
    return {
      'success': true,
      'screenshot': screenshotPath,
      'snapshot': snapshotText,
      'elements_found': found,
      'elements_missing': missing,
      'element_count': elementCount,
      'description_to_verify': desc,
      'hint': 'Compare the screenshot and snapshot against the description.',
    };
  }

  Future<Map<String, dynamic>> _executeVisualDiff(
      Map<String, dynamic> args, AppDriver client) async {
    final quality = (args['quality'] as num?)?.toDouble() ?? 0.5;
    final baselinePath = args['baseline_path'] as String? ?? '';
    if (baselinePath.isEmpty || !await File(baselinePath).exists()) {
      return {
        'success': false,
        'error': 'Baseline file not found: $baselinePath'
      };
    }
    final imageBase64 =
        await client.takeScreenshot(quality: quality, maxWidth: 800);
    String? currentPath;
    if (imageBase64 != null) {
      final ts = DateTime.now().millisecondsSinceEpoch;
      final file =
          File('${Directory.systemTemp.path}/flutter_skill_diff_$ts.png');
      await file.writeAsBytes(base64.decode(imageBase64));
      currentPath = file.path;
    }
    return {
      'success': true,
      'baseline_path': baselinePath,
      'current_screenshot': currentPath,
      'hint':
          'Compare baseline with current screenshot for visual differences.',
    };
  }

  Future<Map<String, dynamic>> _performGesture(
      Map<String, dynamic> args, FlutterSkillClient client) async {
    final preset = args['preset'] as String?;
    final duration = args['duration'] as int? ?? 300;

    double fromX, fromY, toX, toY;
    int gestureDuration = duration;

    if (preset != null) {
      final presetConfig = FlutterMcpServer._gesturePresets[preset];
      if (presetConfig == null) {
        return {
          "success": false,
          "error": {
            "code": "E102",
            "message": "Unknown gesture preset: $preset",
          },
          "available_presets": FlutterMcpServer._gesturePresets.keys.toList(),
        };
      }
      fromX = presetConfig['from_x'] as double;
      fromY = presetConfig['from_y'] as double;
      toX = presetConfig['to_x'] as double;
      toY = presetConfig['to_y'] as double;
      gestureDuration = presetConfig['duration'] as int? ?? duration;
    } else {
      // Custom coordinates
      fromX = (args['from_x'] as num?)?.toDouble() ?? 0.5;
      fromY = (args['from_y'] as num?)?.toDouble() ?? 0.5;
      toX = (args['to_x'] as num?)?.toDouble() ?? 0.5;
      toY = (args['to_y'] as num?)?.toDouble() ?? 0.5;
    }

    // Get screen size to convert ratios to pixels
    final layoutTree = await client.getLayoutTree();
    final screenWidth =
        (layoutTree['size']?['width'] as num?)?.toDouble() ?? 400.0;
    final screenHeight =
        (layoutTree['size']?['height'] as num?)?.toDouble() ?? 800.0;

    // Convert ratios (0.0-1.0) to pixels if values are small
    final startX = fromX <= 1.0 ? fromX * screenWidth : fromX;
    final startY = fromY <= 1.0 ? fromY * screenHeight : fromY;
    final endX = toX <= 1.0 ? toX * screenWidth : toX;
    final endY = toY <= 1.0 ? toY * screenHeight : toY;

    await client.swipeCoordinates(startX, startY, endX, endY,
        duration: gestureDuration);

    return {
      "success": true,
      "gesture": preset ?? "custom",
      "from": {"x": startX.round(), "y": startY.round()},
      "to": {"x": endX.round(), "y": endY.round()},
      "duration": gestureDuration,
    };
  }

  /// Wait for the app to become idle
  Future<Map<String, dynamic>> _waitForIdle(
      Map<String, dynamic> args, FlutterSkillClient client) async {
    final timeout = args['timeout'] as int? ?? 5000;
    final minIdleTime = args['min_idle_time'] as int? ?? 500;

    final stopwatch = Stopwatch()..start();
    var lastActivityTime = DateTime.now();
    var previousTree = '';

    while (stopwatch.elapsedMilliseconds < timeout) {
      // Get current widget tree snapshot
      final tree = await client.getWidgetTree(maxDepth: 3);
      final currentTree = tree.toString();

      if (currentTree == previousTree) {
        // No changes detected
        final idleTime =
            DateTime.now().difference(lastActivityTime).inMilliseconds;
        if (idleTime >= minIdleTime) {
          return {
            "success": true,
            "idle": true,
            "idle_time_ms": idleTime,
            "total_wait_ms": stopwatch.elapsedMilliseconds,
          };
        }
      } else {
        // Activity detected, reset idle timer
        lastActivityTime = DateTime.now();
        previousTree = currentTree;
      }

      await Future.delayed(const Duration(milliseconds: 100));
    }

    return {
      "success": false,
      "idle": false,
      "message": "Timeout waiting for idle state",
      "timeout_ms": timeout,
      "total_wait_ms": stopwatch.elapsedMilliseconds,
    };
  }

  /// Scroll until element becomes visible
  Future<Map<String, dynamic>> _scrollUntilVisible(
      Map<String, dynamic> args, FlutterSkillClient client) async {
    final key = args['key'] as String?;
    final text = args['text'] as String?;
    final direction = args['direction'] ?? 'down';
    final maxScrolls = args['max_scrolls'] ?? 10;
    final scrollableKey = args['scrollable_key'] as String?;

    for (var i = 0; i < maxScrolls; i++) {
      // Check if element is visible
      final found = await client.waitForElement(
        key: key,
        text: text,
        timeout: 500,
      );

      if (found) {
        // Being built (cache extent) is not being visible: bring it into
        // the viewport before reporting success.
        await client.scrollTo(key: key, text: text);
        return {
          "success": true,
          "found": true,
          "scrolls_needed": i,
        };
      }

      // `direction` is the scroll direction ("down" reveals content further
      // down); a swipe is the finger's motion, which is the opposite way.
      const fingerFor = {
        'down': 'up',
        'up': 'down',
        'right': 'left',
        'left': 'right',
      };
      await client.swipe(
        direction: fingerFor[direction] ?? direction,
        distance: 300,
        key: scrollableKey,
      );

      // Let the fling settle before looking again
      await Future.delayed(const Duration(milliseconds: 300));
    }

    return {
      "success": false,
      "found": false,
      "scrolls_attempted": maxScrolls,
      "message": "Element not found after $maxScrolls scrolls",
    };
  }

  /// Assert element visibility
  Future<Map<String, dynamic>> _assertVisible(
      Map<String, dynamic> args, FlutterSkillClient client,
      {required bool shouldBeVisible}) async {
    final key = args['key'] as String?;
    final text = args['text'] as String?;
    final timeout = args['timeout'] ?? 5000;

    if (shouldBeVisible) {
      final found =
          await client.waitForElement(key: key, text: text, timeout: timeout);
      return {
        "success": found,
        "assertion": "visible",
        "element": key ?? text,
        "message": found
            ? "Element is visible"
            : "Element not found within ${timeout}ms",
      };
    } else {
      final gone =
          await client.waitForGone(key: key, text: text, timeout: timeout);
      return {
        "success": gone,
        "assertion": "not_visible",
        "element": key ?? text,
        "message": gone
            ? "Element is not visible"
            : "Element still visible after ${timeout}ms",
      };
    }
  }

  /// Assert text content
  Future<Map<String, dynamic>> _assertText(
      Map<String, dynamic> args, FlutterSkillClient client) async {
    final key = args['key'] as String? ?? args['element'] as String? ?? '';
    final expected =
        args['expected'] as String? ?? args['text'] as String? ?? '';
    final useContains = args['contains'] ?? false;

    final actual = await client.getTextValue(key.isEmpty ? null : key);

    bool matches;
    if (useContains) {
      matches = actual?.contains(expected) ?? false;
    } else {
      matches = actual == expected;
    }

    return {
      "success": matches,
      "assertion": useContains ? "text_contains" : "text_equals",
      "element": key,
      "expected": expected,
      "actual": actual,
      "message": matches
          ? "Text assertion passed"
          : "Text mismatch: expected ${useContains ? 'to contain' : ''} '$expected', got '$actual'",
    };
  }

  /// Assert element count
  Future<Map<String, dynamic>> _assertElementCount(
      Map<String, dynamic> args, FlutterSkillClient client) async {
    final type = args['type'] as String?;
    final text = args['text'] as String?;
    final expectedCount = args['expected_count'] as int?;
    final minCount = args['min_count'] as int?;
    final maxCount = args['max_count'] as int?;

    int count = 0;

    if (type != null) {
      final elements = await client.findByType(type);
      count = elements.length;
    } else if (text != null) {
      final allText = await client.getTextContent();
      count = RegExp(RegExp.escape(text)).allMatches(allText.toString()).length;
    }

    bool success = true;
    String message = "";

    if (expectedCount != null) {
      success = count == expectedCount;
      message = success
          ? "Count matches: $count"
          : "Count mismatch: expected $expectedCount, got $count";
    } else {
      if (minCount != null && count < minCount) {
        success = false;
        message = "Count $count is less than minimum $minCount";
      }
      if (maxCount != null && count > maxCount) {
        success = false;
        message = "Count $count is greater than maximum $maxCount";
      }
      if (success) {
        message = "Count $count is within expected range";
      }
    }

    return {
      "success": success,
      "assertion": "element_count",
      "count": count,
      "message": message,
    };
  }

  /// Get complete page state snapshot
  Future<Map<String, dynamic>> _getPageState(FlutterSkillClient client) async {
    final route = await client.getCurrentRoute();
    final interactables = await client.getInteractiveElements();
    final textContent = await client.getTextContent();

    return {
      "route": route,
      "interactive_elements_count": (interactables as List?)?.length ?? 0,
      "text_content_preview": textContent
          .toString()
          .substring(0, textContent.toString().length.clamp(0, 500)),
      "timestamp": DateTime.now().toIso8601String(),
    };
  }
}
