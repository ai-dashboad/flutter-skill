import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../bridge/cdp_driver.dart';

/// `flutter-skill monkey` — Random fuzz testing for web apps.
///
/// Usage:
///   flutter-skill monkey https://my-app.com [--duration=60] [--actions=100] [--seed=12345] [--report=./monkey-report.html]
Future<void> runMonkey(List<String> args) async {
  String? url;
  int duration = 60;
  int maxActions = 100;
  int? seed;
  String reportPath = './monkey-report.html';
  int cdpPort = 0; // 0 = auto-assign random port
  bool headless = true;
  bool stayOnSite = true;

  for (final arg in args) {
    if (arg.startsWith('--duration=')) {
      duration = int.parse(arg.substring(11));
    } else if (arg.startsWith('--actions=')) {
      maxActions = int.parse(arg.substring(10));
    } else if (arg.startsWith('--seed=')) {
      seed = int.parse(arg.substring(7));
    } else if (arg.startsWith('--report=')) {
      reportPath = arg.substring(9);
    } else if (arg.startsWith('--cdp-port=')) {
      cdpPort = int.parse(arg.substring(11));
    } else if (arg == '--no-headless') {
      headless = false;
    } else if (arg == '--no-stay-on-site') {
      stayOnSite = false;
    } else if (!arg.startsWith('-')) {
      url = arg;
    }
  }

  if (url == null) {
    print('Usage: flutter-skill monkey <url> [options]');
    print('');
    print('Options:');
    print('  --duration=N     Max duration in seconds (default: 60)');
    print('  --actions=N      Max number of actions (default: 100)');
    print('  --seed=N         Random seed for reproducibility');
    print(
        '  --report=PATH    HTML report output (default: ./monkey-report.html)');
    print('  --cdp-port=N     Chrome DevTools port (default: 9222)');
    print('  --no-headless    Show browser window');
    print('  --no-stay-on-site  Allow navigation to external sites');
    exit(1);
  }

  seed ??= DateTime.now().millisecondsSinceEpoch;
  final rng = Random(seed);

  print('🐒 flutter-skill monkey — Random Fuzz Testing');
  print('');
  print('   URL: $url');
  print('   Duration: ${duration}s');
  print('   Max actions: $maxActions');
  print('   Seed: $seed');
  print('   Report: $reportPath');
  print('   Headless: $headless');
  print('');

  // Launch Chrome and connect via CDP
  final cdp = CdpDriver(
    url: url,
    port: cdpPort,
    headless: headless,
    launchChrome: cdpPort == 0,
  );

  try {
    print('🚀 Launching Chrome...');
    await cdp.connect();
    print('✅ Connected to $url');

    // Enable CDP event domains for error detection
    await cdp.sendCommand('Log.enable');
    await cdp.sendCommand('Network.enable');

    // Collect errors and actions
    final errors = <_MonkeyError>[];
    final actions = <_MonkeyAction>[];
    final screenshots = <String, String>{}; // actionIndex -> base64

    // Listen for console errors via CDP events
    cdp.onEvent('Runtime.exceptionThrown', (params) {
      final desc = params['exceptionDetails']?['exception']?['description'] ??
          params['exceptionDetails']?['text'] ??
          'Unknown exception';
      errors.add(_MonkeyError(
        type: 'js_exception',
        message: desc.toString(),
        actionIndex: actions.length,
        timestamp: DateTime.now(),
      ));
      print('  ❌ JS Exception: $desc');
    });

    cdp.onEvent('Log.entryAdded', (params) {
      final entry = params['entry'] as Map<String, dynamic>? ?? {};
      final level = entry['level'] ?? '';
      if (level == 'error') {
        errors.add(_MonkeyError(
          type: 'console_error',
          message: entry['text']?.toString() ?? 'Console error',
          actionIndex: actions.length,
          timestamp: DateTime.now(),
        ));
        print('  ❌ Console Error: ${entry['text']}');
      }
    });

    // Track network errors
    cdp.onEvent('Network.responseReceived', (params) {
      final response = params['response'] as Map<String, dynamic>? ?? {};
      final status = response['status'] as int? ?? 0;
      if (status >= 400) {
        final reqUrl = response['url']?.toString() ?? '';
        errors.add(_MonkeyError(
          type: 'http_error',
          message: 'HTTP $status: $reqUrl',
          actionIndex: actions.length,
          timestamp: DateTime.now(),
        ));
        print('  ❌ HTTP $status: $reqUrl');
      }
    });

    final deadline = DateTime.now().add(Duration(seconds: duration));
    var actionCount = 0;

    print('');
    print('🐒 Starting monkey testing...');
    print('');

    while (actionCount < maxActions && DateTime.now().isBefore(deadline)) {
      actionCount++;

      // Take screenshot before action
      try {
        final img = await cdp.takeScreenshot(quality: 0.5);
        if (img != null) {
          screenshots['$actionCount'] = img;
        }
      } catch (_) {}

      // Discover interactive elements
      List<dynamic> elements = [];
      try {
        elements = await cdp.getInteractiveElements();
      } catch (e) {
        print('  ⚠️  Failed to discover elements: $e');
      }

      if (elements.isEmpty) {
        // If no elements found, try scrolling or navigating
        final action = _MonkeyAction(
          index: actionCount,
          type: 'scroll',
          detail: 'No elements found, scrolling',
          timestamp: DateTime.now(),
        );
        actions.add(action);
        print('  [$actionCount/$maxActions] 📜 Scroll (no elements found)');
        try {
          await cdp.sendCommand('Input.dispatchMouseEvent', {
            'type': 'mouseWheel',
            'x': 200,
            'y': 400,
            'deltaX': 0,
            'deltaY': rng.nextBool() ? 300 : -300,
          });
        } catch (_) {}
        await _monkeyDelay(rng);
        continue;
      }

      // Choose action type: tap 60%, type 20%, scroll 15%, navigate 5%
      final roll = rng.nextDouble();
      if (roll < 0.60) {
        // TAP random element
        final el =
            elements[rng.nextInt(elements.length)] as Map<String, dynamic>;
        final text = el['text']?.toString() ?? el['key']?.toString() ?? '?';
        final action = _MonkeyAction(
          index: actionCount,
          type: 'tap',
          detail: 'Tap: "$text"',
          timestamp: DateTime.now(),
        );
        actions.add(action);
        print('  [$actionCount/$maxActions] 👆 Tap "$text"');
        try {
          final bounds = el['bounds'] as Map<String, dynamic>?;
          if (bounds != null) {
            final cx = (bounds['x'] as num? ?? 0) +
                ((bounds['width'] as num? ?? 0) / 2);
            final cy = (bounds['y'] as num? ?? 0) +
                ((bounds['height'] as num? ?? 0) / 2);
            await cdp.tapAt(cx.toDouble(), cy.toDouble());
          } else {
            await cdp.tap(
                key: el['key']?.toString(), text: el['text']?.toString());
          }
        } catch (e) {
          action.error = e.toString();
        }
      } else if (roll < 0.80) {
        // TYPE random text into a random input
        final inputs = elements.where((e) {
          final t =
              (e as Map<String, dynamic>)['type']?.toString().toLowerCase() ??
                  '';
          return t.contains('input') ||
              t.contains('text') ||
              t.contains('textarea');
        }).toList();
        if (inputs.isNotEmpty) {
          final el = inputs[rng.nextInt(inputs.length)] as Map<String, dynamic>;
          final randomText = _generateRandomText(rng);
          final label = el['text']?.toString() ?? el['key']?.toString() ?? '?';
          final action = _MonkeyAction(
            index: actionCount,
            type: 'type',
            detail: 'Type "$randomText" into "$label"',
            timestamp: DateTime.now(),
          );
          actions.add(action);
          print(
              '  [$actionCount/$maxActions] ⌨️  Type "$randomText" into "$label"');
          try {
            final bounds = el['bounds'] as Map<String, dynamic>?;
            if (bounds != null) {
              final cx = (bounds['x'] as num? ?? 0) +
                  ((bounds['width'] as num? ?? 0) / 2);
              final cy = (bounds['y'] as num? ?? 0) +
                  ((bounds['height'] as num? ?? 0) / 2);
              await cdp.tapAt(cx.toDouble(), cy.toDouble());
            }
            await cdp.enterText(el['key']?.toString(), randomText);
          } catch (e) {
            action.error = e.toString();
          }
        } else {
          // No inputs, do a tap instead
          final el =
              elements[rng.nextInt(elements.length)] as Map<String, dynamic>;
          actions.add(_MonkeyAction(
            index: actionCount,
            type: 'tap',
            detail: 'Tap (no inputs): "${el['text'] ?? '?'}"',
            timestamp: DateTime.now(),
          ));
          try {
            await cdp.tap(
                key: el['key']?.toString(), text: el['text']?.toString());
          } catch (_) {}
        }
      } else if (roll < 0.95) {
        // SCROLL
        final dy = (rng.nextInt(600) - 300).toDouble();
        final action = _MonkeyAction(
          index: actionCount,
          type: 'scroll',
          detail: 'Scroll by $dy px',
          timestamp: DateTime.now(),
        );
        actions.add(action);
        print(
            '  [$actionCount/$maxActions] 📜 Scroll ${dy > 0 ? 'down' : 'up'} ${dy.abs().toInt()}px');
        try {
          await cdp.sendCommand('Input.dispatchMouseEvent', {
            'type': 'mouseWheel',
            'x': 200,
            'y': 400,
            'deltaX': 0,
            'deltaY': dy,
          });
        } catch (e) {
          action.error = e.toString();
        }
      } else {
        // NAVIGATE back
        final action = _MonkeyAction(
          index: actionCount,
          type: 'navigate',
          detail: 'Navigate back',
          timestamp: DateTime.now(),
        );
        actions.add(action);
        print('  [$actionCount/$maxActions] 🔙 Navigate back');
        try {
          await cdp.sendCommand('Runtime.evaluate', {
            'expression': 'history.back()',
          });
        } catch (e) {
          action.error = e.toString();
        }
      }

      // Post-action checks
      await _monkeyDelay(rng);

      // Stay-on-site: if navigated to a different domain, go back
      if (stayOnSite) {
        try {
          final locResult = await cdp.sendCommand('Runtime.evaluate', {
            'expression': 'window.location.href',
            'returnByValue': true,
          });
          final currentUrl = locResult['result']?['value']?.toString() ?? '';
          if (currentUrl.isNotEmpty) {
            final currentHost =
                _rootDomain(Uri.tryParse(currentUrl)?.host ?? '');
            final startHost = _rootDomain(Uri.tryParse(url)?.host ?? '');
            if (currentHost.isNotEmpty &&
                startHost.isNotEmpty &&
                currentHost != startHost) {
              print('  ↩️ Navigated off-site to $currentHost, going back');
              await cdp.sendCommand('Runtime.evaluate', {
                'expression': 'history.back()',
              });
              await Future.delayed(const Duration(seconds: 1));
            }
          }
        } catch (_) {}
      }

      // Check for white screen (crash detection) — with improved logic
      try {
        // Wait 500ms to let page render before checking
        await Future.delayed(const Duration(milliseconds: 500));

        final result = await cdp.sendCommand('Runtime.evaluate', {
          'expression': '''
            JSON.stringify({
              url: window.location.href,
              innerHtmlLen: document.body ? document.body.innerHTML.length : 0
            })
          ''',
          'returnByValue': true,
        });
        final jsonStr = result['result']?['value']?.toString() ?? '{}';
        final data = jsonDecode(jsonStr) as Map<String, dynamic>;
        final currentUrl = data['url'] as String? ?? '';
        final innerHtmlLen = data['innerHtmlLen'] as int? ?? 0;

        // Don't flag special URLs or navigations as white screens
        final isSpecialUrl = currentUrl.startsWith('about:') ||
            currentUrl.startsWith('chrome://') ||
            currentUrl.startsWith('chrome-error://') ||
            currentUrl.startsWith('data:') ||
            currentUrl.isEmpty;

        if (!isSpecialUrl && innerHtmlLen < 50) {
          // Retry after 2.5s to avoid false positives during SPA navigation
          await Future.delayed(const Duration(milliseconds: 2500));
          final retry = await cdp.sendCommand('Runtime.evaluate', {
            'expression': 'document.body ? document.body.innerHTML.length : 0',
            'returnByValue': true,
          });
          final retryLen = retry['result']?['value'] as int? ?? innerHtmlLen;
          if (retryLen >= 100) {
            // Page loaded after retry — not a white screen
          } else {
            errors.add(_MonkeyError(
              type: 'white_screen',
              message:
                  'Page appears blank after retry (innerHTML: $retryLen, possible crash)',
              actionIndex: actionCount,
              timestamp: DateTime.now(),
            ));
            print('  ❌ White screen detected!');
          }
        }
      } catch (_) {}
    }

    print('');
    print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    print('🐒 Monkey Testing Complete');
    print('   Actions: $actionCount');
    print('   Errors: ${errors.length}');
    print('   Duration: ${duration}s (seed: $seed)');
    print('');

    // Generate HTML report
    await _generateMonkeyReport(
      reportPath: reportPath,
      url: url,
      seed: seed,
      actions: actions,
      errors: errors,
      screenshots: screenshots,
    );

    print('📄 Report saved to: $reportPath');
  } catch (e) {
    print('❌ Monkey test failed: $e');
    exit(1);
  } finally {
    await cdp.disconnect();
  }
}

Future<void> _monkeyDelay(Random rng) async {
  await Future.delayed(Duration(milliseconds: 200 + rng.nextInt(800)));
}

String _generateRandomText(Random rng) {
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789 @.!?';
  final len = 3 + rng.nextInt(15);
  return String.fromCharCodes(
    List.generate(len, (_) => chars.codeUnitAt(rng.nextInt(chars.length))),
  );
}

class _MonkeyAction {
  final int index;
  final String type;
  final String detail;
  final DateTime timestamp;
  String? error;

  _MonkeyAction({
    required this.index,
    required this.type,
    required this.detail,
    required this.timestamp,
    // ignore: unused_element_parameter
    this.error = "",
  });
}

class _MonkeyError {
  final String type;
  final String message;
  final int actionIndex;
  final DateTime timestamp;

  _MonkeyError({
    required this.type,
    required this.message,
    required this.actionIndex,
    required this.timestamp,
  });
}

Future<void> _generateMonkeyReport({
  required String reportPath,
  required String url,
  required int seed,
  required List<_MonkeyAction> actions,
  required List<_MonkeyError> errors,
  required Map<String, String> screenshots,
}) async {
  final buf = StringBuffer();
  buf.writeln('<!DOCTYPE html>');
  buf.writeln('<html><head><meta charset="utf-8">');
  buf.writeln('<title>Monkey Test Report</title>');
  buf.writeln('<style>');
  buf.writeln(
      'body { font-family: -apple-system, sans-serif; max-width: 1200px; margin: 0 auto; padding: 20px; background: #f5f5f5; }');
  buf.writeln('h1 { color: #333; } h2 { color: #555; margin-top: 30px; }');
  buf.writeln(
      '.summary { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 16px; margin: 20px 0; }');
  buf.writeln(
      '.card { background: white; border-radius: 8px; padding: 20px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }');
  buf.writeln(
      '.card h3 { margin-top: 0; font-size: 14px; color: #888; } .card .value { font-size: 32px; font-weight: bold; }');
  buf.writeln(
      '.error { background: #fff0f0; border-left: 4px solid #e74c3c; padding: 12px; margin: 8px 0; border-radius: 4px; }');
  buf.writeln(
      '.action { background: white; padding: 8px 12px; margin: 4px 0; border-radius: 4px; display: flex; align-items: center; gap: 12px; }');
  buf.writeln(
      '.action .idx { color: #999; font-size: 12px; min-width: 40px; }');
  buf.writeln('.action .type { font-weight: bold; min-width: 80px; }');
  buf.writeln(
      '.screenshot { max-width: 300px; border-radius: 4px; margin: 4px 0; cursor: pointer; }');
  buf.writeln(
      '.screenshot:hover { transform: scale(1.5); transition: transform 0.2s; }');
  buf.writeln(
      '.tap { color: #3498db; } .type-text { color: #2ecc71; } .scroll { color: #f39c12; } .navigate { color: #9b59b6; }');
  buf.writeln('</style></head><body>');
  buf.writeln('<h1>🐒 Monkey Test Report</h1>');
  buf.writeln(
      '<p>URL: <a href="${_escHtml(url)}">${_escHtml(url)}</a> | Seed: <code>$seed</code></p>');

  buf.writeln('<div class="summary">');
  buf.writeln(
      '<div class="card"><h3>Actions</h3><div class="value">${actions.length}</div></div>');
  buf.writeln(
      '<div class="card"><h3>Errors</h3><div class="value" style="color:${errors.isEmpty ? '#2ecc71' : '#e74c3c'}">${errors.length}</div></div>');
  final crashCount = errors.where((e) => e.type == 'white_screen').length;
  buf.writeln(
      '<div class="card"><h3>Crashes</h3><div class="value" style="color:${crashCount == 0 ? '#2ecc71' : '#e74c3c'}">$crashCount</div></div>');
  buf.writeln(
      '<div class="card"><h3>HTTP Errors</h3><div class="value">${errors.where((e) => e.type == 'http_error').length}</div></div>');
  buf.writeln('</div>');

  if (errors.isNotEmpty) {
    buf.writeln('<h2>❌ Errors Found</h2>');
    for (final err in errors) {
      buf.writeln(
          '<div class="error"><strong>[${err.type}]</strong> at action #${err.actionIndex}: ${_escHtml(err.message)}</div>');
    }
  }

  buf.writeln('<h2>📋 Action Sequence</h2>');
  for (final action in actions) {
    final typeClass = action.type == 'type' ? 'type-text' : action.type;
    buf.writeln('<div class="action">');
    buf.writeln('  <span class="idx">#${action.index}</span>');
    buf.writeln(
        '  <span class="type $typeClass">${action.type.toUpperCase()}</span>');
    buf.writeln('  <span>${_escHtml(action.detail)}</span>');
    if (action.error != null) {
      buf.writeln(
          '  <span style="color:red">⚠ ${_escHtml(action.error ?? "")}</span>');
    }
    // Inline screenshot thumbnail
    final scr = screenshots['${action.index}'];
    if (scr != null && scr.length < 200000) {
      buf.writeln(
          '  <img class="screenshot" src="data:image/jpeg;base64,$scr" alt="action ${action.index}">');
    }
    buf.writeln('</div>');
  }

  buf.writeln('</body></html>');

  final file = File(reportPath);
  await file.parent.create(recursive: true);
  await file.writeAsString(buf.toString());
}

String _escHtml(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

/// Extract root domain (e.g. "www.amazon.com" → "amazon.com")
String _rootDomain(String host) {
  final parts = host.split('.');
  if (parts.length <= 2) return host;
  return parts.sublist(parts.length - 2).join('.');
}
