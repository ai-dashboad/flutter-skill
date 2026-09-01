part of '../server.dart';

extension _BfAssertions on FlutterMcpServer {
  Future<dynamic> _handleAssertionTool(
      String name, Map<String, dynamic> args, AppDriver? client) async {
    switch (name) {
      case 'assert_batch':
        final assertions = (args['assertions'] as List<dynamic>?) ?? [];
        final results = <Map<String, dynamic>>[];
        int passed = 0;
        int failed = 0;
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
            final success = result is Map && result['success'] == true;
            if (success)
              passed++;
            else
              failed++;
            results.add({'type': aType, 'success': success, 'result': result});
          } catch (e) {
            failed++;
            results
                .add({'type': aType, 'success': false, 'error': e.toString()});
          }
        }
        return {
          'success': failed == 0,
          'total': assertions.length,
          'passed': passed,
          'failed': failed,
          'results': results,
        };

      // === NEW: Assertions ===
      case 'assert_visible':
        if (client is BridgeDriver) {
          final found =
              await client.findElement(key: args['key'], text: args['text']);
          final isVisible = found.isNotEmpty && found['found'] == true;
          return {
            "success": isVisible,
            "visible": isVisible,
            "message": isVisible ? "Element is visible" : "Element not found"
          };
        }
        final fc = _asFlutterClient(client!, 'assert_visible');
        return await _assertVisible(args, fc, shouldBeVisible: true);

      case 'assert_not_visible':
        if (client is BridgeDriver) {
          final found =
              await client.findElement(key: args['key'], text: args['text']);
          final isGone = found.isEmpty || found['found'] != true;
          return {
            "success": isGone,
            "visible": !isGone,
            "message":
                isGone ? "Element is not visible" : "Element is still visible"
          };
        }
        final fc = _asFlutterClient(client!, 'assert_not_visible');
        return await _assertVisible(args, fc, shouldBeVisible: false);

      case 'assert_text':
        if (client is BridgeDriver) {
          final actual = await client.getText(key: args['key']);
          final expected = args['expected'] as String?;
          final matches = actual == expected;
          return {
            "success": matches,
            "actual": actual,
            "expected": expected,
            "message": matches ? "Text matches" : "Text mismatch"
          };
        }
        final fc = _asFlutterClient(client!, 'assert_text');
        return await _assertText(args, fc);

      case 'assert_element_count':
        if (client is BridgeDriver) {
          final elements = await client.getInteractiveElements();
          final count = elements.length;
          final expected = args['expected'] as int?;
          final matches = expected == null || count == expected;
          return {
            "success": matches,
            "count": count,
            "expected": expected,
            "message": matches
                ? "Count matches"
                : "Expected $expected but found $count"
          };
        }
        final fc = _asFlutterClient(client!, 'assert_element_count');
        return await _assertElementCount(args, fc);

      // === NEW: Page State ===
      default:
        return null;
    }
  }
}
