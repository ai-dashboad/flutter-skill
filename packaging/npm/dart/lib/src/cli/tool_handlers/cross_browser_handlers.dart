part of '../server.dart';

/// Browser emulation presets with user-agent strings and viewport configs.
const _browserPresets = <String, Map<String, dynamic>>{
  'chrome_desktop': {
    'ua':
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'width': 1440,
    'height': 900,
    'mobile': false,
    'deviceScaleFactor': 1,
  },
  'chrome_mobile': {
    'ua':
        'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
    'width': 412,
    'height': 915,
    'mobile': true,
    'deviceScaleFactor': 2.625,
  },
  'safari_iphone': {
    'ua':
        'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
    'width': 393,
    'height': 852,
    'mobile': true,
    'deviceScaleFactor': 3,
  },
  'safari_ipad': {
    'ua':
        'Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
    'width': 1024,
    'height': 1366,
    'mobile': false,
    'deviceScaleFactor': 2,
  },
  'firefox_desktop': {
    'ua':
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:120.0) Gecko/20100101 Firefox/120.0',
    'width': 1440,
    'height': 900,
    'mobile': false,
    'deviceScaleFactor': 1,
  },
  'edge_desktop': {
    'ua':
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 Edg/120.0.0.0',
    'width': 1440,
    'height': 900,
    'mobile': false,
    'deviceScaleFactor': 1,
  },
};

extension _CrossBrowserHandlers on FlutterMcpServer {
  Future<dynamic> _handleCrossBrowserTools(
      String name, Map<String, dynamic> args) async {
    switch (name) {
      case 'cross_browser_test':
        return _crossBrowserTest(args);
      case 'responsive_test':
        return _responsiveTest(args);
      default:
        return null;
    }
  }

  /// Run the same test across multiple browser emulations.
  Future<Map<String, dynamic>> _crossBrowserTest(
      Map<String, dynamic> args) async {
    final cdp = _cdpDriver;
    if (cdp == null) {
      return {'success': false, 'error': 'CDP connection required'};
    }

    final url = args['url'] as String?;
    if (url == null || url.isEmpty) {
      return {'success': false, 'error': 'url is required'};
    }

    final browsers = (args['browsers'] as List<dynamic>?)?.cast<String>() ??
        ['chrome_desktop', 'chrome_mobile', 'safari_iphone'];
    final actions = (args['actions'] as List<dynamic>?) ?? [];

    final results = <Map<String, dynamic>>[];

    for (final browser in browsers) {
      final preset = _browserPresets[browser];
      if (preset == null) {
        results.add({
          'browser': browser,
          'success': false,
          'error': 'Unknown browser preset',
        });
        continue;
      }

      final browserResult = <String, dynamic>{
        'browser': browser,
        'viewport': {'width': preset['width'], 'height': preset['height']},
        'mobile': preset['mobile'],
      };

      try {
        // Set device metrics
        await cdp.sendCommand('Emulation.setDeviceMetricsOverride', {
          'width': preset['width'] as int,
          'height': preset['height'] as int,
          'deviceScaleFactor':
              (preset['deviceScaleFactor'] as num?)?.toDouble() ?? 1.0,
          'mobile': preset['mobile'] as bool? ?? false,
        });

        // Set user agent
        await cdp.sendCommand('Emulation.setUserAgentOverride', {
          'userAgent': preset['ua'] as String,
        });

        // Enable log collection for this browser config
        final consoleErrors = <String>[];
        await cdp.sendCommand('Log.enable', {});
        cdp.onEvent('Log.entryAdded', (params) {
          final entry = params['entry'] as Map<String, dynamic>?;
          if (entry != null && entry['level'] == 'error') {
            consoleErrors.add(entry['text'] as String? ?? '');
          }
        });

        // Navigate to URL
        await cdp.sendCommand('Page.navigate', {'url': url});
        await Future.delayed(const Duration(seconds: 3));

        // Execute actions if any
        final actionResults = <Map<String, dynamic>>[];
        for (final action in actions) {
          if (action is Map<String, dynamic>) {
            final actionName = (action['action'] ??
                action['tool'] ??
                action['name']) as String?;
            if (actionName != null) {
              try {
                final actionArgs =
                    action['args'] as Map<String, dynamic>? ?? {};
                final result = await _executeTool(actionName, actionArgs);
                actionResults.add({
                  'action': actionName,
                  'success': true,
                  'result': result,
                });
              } catch (e) {
                actionResults.add({
                  'action': actionName,
                  'success': false,
                  'error': e.toString(),
                });
              }
            }
          }
        }

        // Take screenshot
        final screenshotResult =
            await cdp.sendCommand('Page.captureScreenshot', {
          'format': 'png',
        });
        final screenshotData = screenshotResult['data'] as String? ?? '';

        // Check page state
        final stateResult = await cdp.call('Runtime.evaluate', {
          'expression': '''
JSON.stringify({
  title: document.title,
  url: location.href,
  scrollWidth: document.documentElement.scrollWidth,
  clientWidth: document.documentElement.clientWidth,
  hasHorizontalOverflow: document.documentElement.scrollWidth > document.documentElement.clientWidth,
  bodyHeight: document.body ? document.body.scrollHeight : 0,
  visibleElements: document.querySelectorAll('*:not(script):not(style)').length,
})
''',
          'returnByValue': true,
        });

        final pageState =
            jsonDecode(stateResult['result']?['value'] as String? ?? '{}')
                as Map<String, dynamic>;

        cdp.removeEventListeners('Log.entryAdded');

        browserResult['success'] = true;
        browserResult['page_state'] = pageState;
        browserResult['console_errors'] = consoleErrors;
        browserResult['console_error_count'] = consoleErrors.length;
        browserResult['has_horizontal_overflow'] =
            pageState['hasHorizontalOverflow'] ?? false;
        browserResult['action_results'] = actionResults;
        browserResult['screenshot_base64'] = screenshotData.length > 100
            ? '${screenshotData.substring(0, 100)}... (${screenshotData.length} chars)'
            : screenshotData;
      } catch (e) {
        browserResult['success'] = false;
        browserResult['error'] = e.toString();
        try {
          cdp.removeEventListeners('Log.entryAdded');
        } catch (_) {}
      }

      results.add(browserResult);
    }

    // Reset emulation
    try {
      await cdp.sendCommand('Emulation.clearDeviceMetricsOverride', {});
      await cdp.sendCommand('Emulation.setUserAgentOverride', {
        'userAgent': '',
      });
    } catch (_) {}

    // Compare results across browsers
    final comparison = _compareBrowserResults(results);

    return {
      'success': true,
      'url': url,
      'browsers_tested': results.length,
      'results': results,
      'comparison': comparison,
    };
  }

  Map<String, dynamic> _compareBrowserResults(
      List<Map<String, dynamic>> results) {
    final successful = results.where((r) => r['success'] == true).toList();
    if (successful.length < 2) {
      return {'message': 'Not enough successful results to compare'};
    }

    final issues = <String>[];

    // Check for overflow differences
    final overflowBrowsers = successful
        .where((r) => r['has_horizontal_overflow'] == true)
        .map((r) => r['browser'] as String)
        .toList();
    if (overflowBrowsers.isNotEmpty &&
        overflowBrowsers.length < successful.length) {
      issues.add(
          'Horizontal overflow detected only in: ${overflowBrowsers.join(", ")}');
    }

    // Check for error differences
    final errorCounts = <String, int>{};
    for (final r in successful) {
      errorCounts[r['browser'] as String] =
          r['console_error_count'] as int? ?? 0;
    }
    final maxErrors = errorCounts.values.fold(0, max);
    final minErrors = errorCounts.values.fold(maxErrors, min);
    if (maxErrors > 0 && maxErrors != minErrors) {
      issues.add('Console errors vary across browsers: ${errorCounts}');
    }

    return {
      'issues_found': issues.length,
      'issues': issues,
      'all_browsers_consistent': issues.isEmpty,
    };
  }

  /// Test responsive design across multiple viewport sizes.
  Future<Map<String, dynamic>> _responsiveTest(
      Map<String, dynamic> args) async {
    final cdp = _cdpDriver;
    if (cdp == null) {
      return {'success': false, 'error': 'CDP connection required'};
    }

    final url = args['url'] as String?;
    if (url == null || url.isEmpty) {
      return {'success': false, 'error': 'url is required'};
    }

    final viewports = (args['viewports'] as List<dynamic>?)?.map((v) {
          if (v is Map<String, dynamic>) return v;
          return <String, dynamic>{};
        }).toList() ??
        [
          {'name': 'mobile', 'width': 375, 'height': 812},
          {'name': 'tablet', 'width': 768, 'height': 1024},
          {'name': 'desktop', 'width': 1440, 'height': 900},
        ];

    final saveScreenshots = args['save_screenshots'] as bool? ?? true;
    final saveDir = args['save_dir'] as String? ?? './responsive-screenshots';

    final results = <Map<String, dynamic>>[];

    for (final vp in viewports) {
      final vpName = vp['name'] as String? ?? 'unknown';
      final width = vp['width'] as int? ?? 1440;
      final height = vp['height'] as int? ?? 900;

      final vpResult = <String, dynamic>{
        'viewport': vpName,
        'width': width,
        'height': height,
      };

      try {
        // Set viewport
        await cdp.sendCommand('Emulation.setDeviceMetricsOverride', {
          'width': width,
          'height': height,
          'deviceScaleFactor': 1,
          'mobile': width < 768,
        });

        // Navigate
        await cdp.sendCommand('Page.navigate', {'url': url});
        await Future.delayed(const Duration(seconds: 3));

        // Check layout issues
        final layoutResult = await cdp.call('Runtime.evaluate', {
          'expression': '''
(() => {
  const docEl = document.documentElement;
  const body = document.body;
  const issues = [];

  // Check horizontal overflow
  if (docEl.scrollWidth > docEl.clientWidth) {
    issues.push({
      type: 'horizontal_overflow',
      scrollWidth: docEl.scrollWidth,
      clientWidth: docEl.clientWidth,
      overflow: docEl.scrollWidth - docEl.clientWidth,
    });
  }

  // Find overflowing elements
  const allEls = document.querySelectorAll('*');
  const overflowing = [];
  for (const el of allEls) {
    if (el.scrollWidth > el.clientWidth + 1 && el !== docEl && el !== body) {
      const rect = el.getBoundingClientRect();
      if (rect.right > docEl.clientWidth) {
        overflowing.push({
          tag: el.tagName.toLowerCase(),
          id: el.id || '',
          class: el.className ? el.className.toString().substring(0, 100) : '',
          width: rect.width,
          overflow: rect.right - docEl.clientWidth,
        });
      }
    }
  }
  if (overflowing.length > 0) {
    issues.push({
      type: 'overflowing_elements',
      count: overflowing.length,
      elements: overflowing.slice(0, 10),
    });
  }

  // Check for text truncation (elements with overflow:hidden and text)
  const truncated = [];
  for (const el of allEls) {
    const style = getComputedStyle(el);
    if (style.overflow === 'hidden' && style.textOverflow === 'ellipsis' && el.scrollWidth > el.clientWidth) {
      truncated.push({
        tag: el.tagName.toLowerCase(),
        text: el.textContent.trim().substring(0, 50),
      });
    }
  }
  if (truncated.length > 0) {
    issues.push({type: 'text_truncation', count: truncated.length, elements: truncated.slice(0, 10)});
  }

  return JSON.stringify({
    issues: issues,
    page_height: body ? body.scrollHeight : 0,
    visible_area: {width: docEl.clientWidth, height: docEl.clientHeight},
  });
})()
''',
          'returnByValue': true,
        });

        final layoutData =
            jsonDecode(layoutResult['result']?['value'] as String? ?? '{}')
                as Map<String, dynamic>;

        vpResult['issues'] = layoutData['issues'] ?? [];
        vpResult['page_height'] = layoutData['page_height'];
        vpResult['visible_area'] = layoutData['visible_area'];
        vpResult['issue_count'] =
            (layoutData['issues'] as List<dynamic>?)?.length ?? 0;

        // Take screenshot
        if (saveScreenshots) {
          final screenshotResult =
              await cdp.sendCommand('Page.captureScreenshot', {
            'format': 'png',
            'captureBeyondViewport': true,
          });

          final screenshotData = screenshotResult['data'] as String? ?? '';
          if (screenshotData.isNotEmpty) {
            final dir = Directory(saveDir);
            if (!await dir.exists()) {
              await dir.create(recursive: true);
            }
            final filePath = '$saveDir/${vpName}_${width}x$height.png';
            await File(filePath).writeAsBytes(base64Decode(screenshotData));
            vpResult['screenshot_path'] = filePath;
          }
        }

        vpResult['success'] = true;
      } catch (e) {
        vpResult['success'] = false;
        vpResult['error'] = e.toString();
      }

      results.add(vpResult);
    }

    // Reset emulation
    try {
      await cdp.sendCommand('Emulation.clearDeviceMetricsOverride', {});
    } catch (_) {}

    return {
      'success': true,
      'url': url,
      'viewports_tested': results.length,
      'results': results,
      'total_issues': results.fold<int>(
          0, (sum, r) => sum + (r['issue_count'] as int? ?? 0)),
    };
  }
}
