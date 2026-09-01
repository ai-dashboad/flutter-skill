part of '../server.dart';

extension _SmartWaitHandlers on FlutterMcpServer {
  /// Handle smart wait tools.
  /// Returns null if the tool is not handled by this group.
  Future<dynamic> _handleSmartWaitTools(
      String name, Map<String, dynamic> args) async {
    switch (name) {
      case 'wait_for_stable':
        return _handleWaitForStable(args);
      case 'wait_for_url':
        return _handleWaitForUrl(args);
      case 'wait_for_text':
        return _handleWaitForText(args);
      case 'wait_for_element_count':
        return _handleWaitForElementCount(args);
      default:
        return null;
    }
  }

  Future<Map<String, dynamic>> _handleWaitForStable(
      Map<String, dynamic> args) async {
    final timeoutMs = args['timeout_ms'] as int? ?? 10000;
    final stabilityMs = args['stability_ms'] as int? ?? 500;
    final client = _getClient(args);

    // CDP mode: use MutationObserver + network idle detection
    if (client is CdpDriver) {
      return _waitForStableCdp(client, timeoutMs, stabilityMs);
    }

    // Bridge/Flutter mode: poll element tree for stability
    if (client != null) {
      return _waitForStableBridge(client, timeoutMs, stabilityMs);
    }

    return {'success': false, 'error': 'No active connection'};
  }

  Future<Map<String, dynamic>> _waitForStableCdp(
      CdpDriver cdp, int timeoutMs, int stabilityMs) async {
    final js = '''
    (() => {
      return new Promise((resolve) => {
        let lastChange = Date.now();
        let resolved = false;
        const stabilityMs = $stabilityMs;
        const timeoutMs = $timeoutMs;
        const startTime = Date.now();

        const observer = new MutationObserver(() => { lastChange = Date.now(); });
        observer.observe(document.body, { childList: true, subtree: true, attributes: true, characterData: true });

        if (window.PerformanceObserver) {
          try {
            const perfObs = new PerformanceObserver(() => { lastChange = Date.now(); });
            perfObs.observe({ entryTypes: ['resource'] });
          } catch(e) {}
        }

        const check = () => {
          if (resolved) return;
          const elapsed = Date.now() - lastChange;
          if (elapsed >= stabilityMs) {
            resolved = true;
            observer.disconnect();
            resolve({ stable: true, waited_ms: Date.now() - startTime });
          } else if (Date.now() - startTime > timeoutMs) {
            resolved = true;
            observer.disconnect();
            resolve({ stable: false, reason: 'timeout', waited_ms: timeoutMs });
          } else {
            setTimeout(check, 100);
          }
        };
        setTimeout(check, stabilityMs);
      });
    })()
    ''';

    try {
      final result = await cdp.evaluate(js);
      final value = result['result']?['value'];
      if (value is Map) {
        return {
          'success': true,
          'stable': value['stable'] ?? false,
          'waited_ms': value['waited_ms'] ?? 0,
          if (value['reason'] != null) 'reason': value['reason'],
        };
      }
      return {'success': true, 'stable': true};
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  Future<Map<String, dynamic>> _waitForStableBridge(
      AppDriver client, int timeoutMs, int stabilityMs) async {
    final sw = Stopwatch()..start();
    String? lastSnapshot;
    int stableSince = 0;

    while (sw.elapsedMilliseconds < timeoutMs) {
      try {
        final elements = await client.getInteractiveElements();
        final snapshotStr = jsonEncode(elements);

        if (snapshotStr == lastSnapshot) {
          if (stableSince == 0) {
            stableSince = sw.elapsedMilliseconds;
          } else if (sw.elapsedMilliseconds - stableSince >= stabilityMs) {
            return {
              'success': true,
              'stable': true,
              'waited_ms': sw.elapsedMilliseconds,
            };
          }
        } else {
          lastSnapshot = snapshotStr;
          stableSince = 0;
        }
      } catch (_) {
        stableSince = 0;
      }

      await Future.delayed(const Duration(milliseconds: 100));
    }

    return {
      'success': true,
      'stable': false,
      'reason': 'timeout',
      'waited_ms': timeoutMs,
    };
  }

  Future<Map<String, dynamic>> _handleWaitForUrl(
      Map<String, dynamic> args) async {
    final urlPattern = args['url_pattern'] as String?;
    final timeoutMs = args['timeout_ms'] as int? ?? 10000;

    if (urlPattern == null) {
      return {
        'success': false,
        'error':
            'url_pattern parameter is required. Provide a regex pattern to match the URL.'
      };
    }

    final client = _getClient(args);
    if (client == null) {
      return {'success': false, 'error': 'No active connection'};
    }

    final regex = RegExp(urlPattern);
    final sw = Stopwatch()..start();

    while (sw.elapsedMilliseconds < timeoutMs) {
      try {
        String? currentUrl;
        if (client is CdpDriver) {
          final result = await client.evaluate('window.location.href');
          final value = result['result']?['value'];
          currentUrl = value?.toString();
        }

        if (currentUrl != null && regex.hasMatch(currentUrl)) {
          return {
            'success': true,
            'matched': true,
            'url': currentUrl,
            'waited_ms': sw.elapsedMilliseconds,
          };
        }
      } catch (_) {
        // Continue polling
      }

      await Future.delayed(const Duration(milliseconds: 100));
    }

    return {
      'success': true,
      'matched': false,
      'reason': 'timeout',
      'waited_ms': timeoutMs,
    };
  }

  Future<Map<String, dynamic>> _handleWaitForText(
      Map<String, dynamic> args) async {
    final text = args['text'] as String?;
    final timeoutMs = args['timeout_ms'] as int? ?? 10000;

    if (text == null) {
      return {'success': false, 'error': 'text is required'};
    }

    final client = _getClient(args);
    if (client == null) {
      return {'success': false, 'error': 'No active connection'};
    }

    final sw = Stopwatch()..start();

    while (sw.elapsedMilliseconds < timeoutMs) {
      try {
        bool found = false;

        if (client is CdpDriver) {
          final result = await client.evaluate(
              'document.body.innerText.includes(${jsonEncode(text)})');
          found = result['result']?['value'] == true;
        } else {
          // Bridge/Flutter: check element tree for text
          final elements = await client.getInteractiveElements();
          final elemStr = jsonEncode(elements);
          found = elemStr.contains(text);
        }

        if (found) {
          return {
            'success': true,
            'found': true,
            'text': text,
            'waited_ms': sw.elapsedMilliseconds,
          };
        }
      } catch (_) {
        // Continue polling
      }

      await Future.delayed(const Duration(milliseconds: 100));
    }

    return {
      'success': true,
      'found': false,
      'reason': 'timeout',
      'text': text,
      'waited_ms': timeoutMs,
    };
  }

  Future<Map<String, dynamic>> _handleWaitForElementCount(
      Map<String, dynamic> args) async {
    final selector = args['selector'] as String?;
    final count = args['count'] as int?;
    final comparison = args['comparison'] as String? ?? 'eq';
    final timeoutMs = args['timeout_ms'] as int? ?? 10000;

    if (selector == null) {
      return {'success': false, 'error': 'selector is required'};
    }

    final client = _getClient(args);
    if (client == null) {
      return {'success': false, 'error': 'No active connection'};
    }

    final sw = Stopwatch()..start();

    while (sw.elapsedMilliseconds < timeoutMs) {
      try {
        int actualCount = 0;

        if (client is CdpDriver) {
          final result = await client.evaluate(
              'document.querySelectorAll(${jsonEncode(selector)}).length');
          final value = result['result']?['value'];
          actualCount =
              (value is int) ? value : int.tryParse(value.toString()) ?? 0;
        } else {
          // Bridge: count matching elements
          final elements = await client.getInteractiveElements();
          actualCount = elements.where((e) {
            if (e is Map) {
              final key = e['key']?.toString() ?? '';
              final type = e['type']?.toString() ?? '';
              final widget = e['widget']?.toString() ?? '';
              return key.contains(selector) ||
                  type.contains(selector) ||
                  widget.contains(selector);
            }
            return false;
          }).length;
        }

        final expected = count ?? 0;
        bool matched = false;
        switch (comparison) {
          case 'eq':
            matched = actualCount == expected;
            break;
          case 'gt':
            matched = actualCount > expected;
            break;
          case 'lt':
            matched = actualCount < expected;
            break;
          case 'gte':
            matched = actualCount >= expected;
            break;
          case 'lte':
            matched = actualCount <= expected;
            break;
        }

        if (matched) {
          return {
            'success': true,
            'matched': true,
            'actual_count': actualCount,
            'expected': count,
            'comparison': comparison,
            'waited_ms': sw.elapsedMilliseconds,
          };
        }
      } catch (_) {
        // Continue polling
      }

      await Future.delayed(const Duration(milliseconds: 100));
    }

    return {
      'success': true,
      'matched': false,
      'reason': 'timeout',
      'selector': selector,
      'waited_ms': timeoutMs,
    };
  }
}
