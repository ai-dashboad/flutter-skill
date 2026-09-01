part of '../server.dart';

/// Network condition presets for throttling simulation.
const _networkPresets = <String, Map<String, num>>{
  'slow_3g': {
    'downloadThroughput': 50000,
    'uploadThroughput': 12500,
    'latency': 300
  },
  'fast_3g': {
    'downloadThroughput': 187500,
    'uploadThroughput': 43750,
    'latency': 100
  },
  'regular_4g': {
    'downloadThroughput': 500000,
    'uploadThroughput': 125000,
    'latency': 50
  },
  'wifi': {
    'downloadThroughput': 3750000,
    'uploadThroughput': 1500000,
    'latency': 10
  },
};

extension _NetworkConditionHandlers on FlutterMcpServer {
  Future<dynamic> _handleNetworkConditionTools(
      String name, Map<String, dynamic> args) async {
    switch (name) {
      case 'test_offline_forms':
        return _testOfflineForms(args);
      case 'test_network_transitions':
        return _testNetworkTransitions(args);
      case 'test_request_timeout':
        return _testRequestTimeout(args);
      default:
        return null;
    }
  }

  /// Discover all forms, fill with test data, go offline, submit, check errors.
  Future<Map<String, dynamic>> _testOfflineForms(
      Map<String, dynamic> args) async {
    final cdp = _cdpDriver;
    if (cdp == null) {
      return {'success': false, 'error': 'CDP connection required'};
    }
    final restoreAfter = args['restore_after'] as bool? ?? true;

    try {
      // Discover forms and their inputs
      final formsResult = await cdp.call('Runtime.evaluate', {
        'expression': '''
(() => {
  const forms = document.querySelectorAll('form');
  const result = [];
  // Also find orphan inputs not inside a form
  const allInputs = document.querySelectorAll('input, textarea, select');
  const orphanInputs = [];
  allInputs.forEach(inp => {
    if (!inp.closest('form')) orphanInputs.push(inp);
  });

  const describeInputs = (container) => {
    const inputs = container.querySelectorAll('input, textarea, select');
    return Array.from(inputs).map(inp => ({
      tag: inp.tagName.toLowerCase(),
      type: inp.type || 'text',
      name: inp.name || inp.id || '',
      id: inp.id || '',
      placeholder: inp.placeholder || '',
    }));
  };

  forms.forEach((form, idx) => {
    result.push({
      index: idx,
      id: form.id || '',
      action: form.action || '',
      method: form.method || 'get',
      inputs: describeInputs(form),
      hasSubmitButton: !!form.querySelector('[type="submit"], button:not([type="button"])'),
    });
  });

  if (orphanInputs.length > 0) {
    result.push({
      index: forms.length,
      id: '__orphan__',
      action: '',
      method: '',
      inputs: orphanInputs.map(inp => ({
        tag: inp.tagName.toLowerCase(),
        type: inp.type || 'text',
        name: inp.name || inp.id || '',
        id: inp.id || '',
        placeholder: inp.placeholder || '',
      })),
      hasSubmitButton: false,
    });
  }

  return JSON.stringify(result);
})()
''',
        'returnByValue': true,
      });

      final formsJson = formsResult['result']?['value'] as String? ?? '[]';
      final forms = jsonDecode(formsJson) as List<dynamic>;

      if (forms.isEmpty) {
        return {
          'success': true,
          'forms_found': 0,
          'message': 'No forms found on page'
        };
      }

      final results = <Map<String, dynamic>>[];

      for (final form in forms) {
        final formIndex = form['index'] as int;
        final formId = form['id'] as String? ?? '';
        final inputs = form['inputs'] as List<dynamic>;
        final formResult = <String, dynamic>{
          'form_index': formIndex,
          'form_id': formId,
          'input_count': inputs.length,
        };

        try {
          // Fill test data into each input
          for (final input in inputs) {
            final selector = _buildInputSelector(input);
            final testValue = _generateTestValue(input);
            await cdp.call('Runtime.evaluate', {
              'expression': '''
(() => {
  const el = document.querySelector('$selector');
  if (el) {
    el.value = '$testValue';
    el.dispatchEvent(new Event('input', {bubbles: true}));
    el.dispatchEvent(new Event('change', {bubbles: true}));
  }
})()
''',
              'returnByValue': true,
            });
          }

          // Go offline
          await cdp.sendCommand('Network.emulateNetworkConditions', {
            'offline': true,
            'latency': 0,
            'downloadThroughput': -1,
            'uploadThroughput': -1,
          });

          // Submit the form
          await cdp.call('Runtime.evaluate', {
            'expression': '''
(() => {
  const forms = document.querySelectorAll('form');
  if (forms[$formIndex]) {
    const btn = forms[$formIndex].querySelector('[type="submit"], button:not([type="button"])');
    if (btn) btn.click();
    else forms[$formIndex].submit();
  }
})()
''',
            'returnByValue': true,
          });

          // Wait a moment for error messages to appear
          await Future.delayed(const Duration(milliseconds: 2000));

          // Check for error indicators
          final errorCheck = await cdp.call('Runtime.evaluate', {
            'expression': '''
(() => {
  const errorSelectors = [
    '.error', '.alert', '.warning', '.toast',
    '[role="alert"]', '.notification',
    '.error-message', '.form-error', '.field-error',
    '.snackbar', '.MuiAlert-root', '.ant-message',
  ];
  const errors = [];
  for (const sel of errorSelectors) {
    document.querySelectorAll(sel).forEach(el => {
      const text = el.textContent.trim();
      if (text) errors.push({selector: sel, text: text.substring(0, 200)});
    });
  }
  return JSON.stringify({
    errors: errors,
    hasOfflineIndicator: !!document.querySelector('.offline, [data-offline], .no-connection'),
  });
})()
''',
            'returnByValue': true,
          });

          final errorData =
              jsonDecode(errorCheck['result']?['value'] as String? ?? '{}');
          formResult['offline_errors_shown'] = errorData['errors'] ?? [];
          formResult['has_offline_indicator'] =
              errorData['hasOfflineIndicator'] ?? false;

          // Restore network
          await cdp.sendCommand('Network.emulateNetworkConditions', {
            'offline': false,
            'latency': 0,
            'downloadThroughput': -1,
            'uploadThroughput': -1,
          });

          // Wait and check for retry/recovery
          await Future.delayed(const Duration(milliseconds: 3000));

          final recoveryCheck = await cdp.call('Runtime.evaluate', {
            'expression': '''
(() => {
  const successSelectors = ['.success', '.alert-success', '[role="status"]', '.toast-success'];
  const found = [];
  for (const sel of successSelectors) {
    document.querySelectorAll(sel).forEach(el => {
      const text = el.textContent.trim();
      if (text) found.push({selector: sel, text: text.substring(0, 200)});
    });
  }
  // Check if form values persisted
  const forms = document.querySelectorAll('form');
  let valuesPersisted = false;
  if (forms[${formIndex}]) {
    const inputs = forms[${formIndex}].querySelectorAll('input, textarea');
    valuesPersisted = Array.from(inputs).some(inp => inp.value.length > 0);
  }
  return JSON.stringify({
    recovery_indicators: found,
    values_persisted: valuesPersisted,
  });
})()
''',
            'returnByValue': true,
          });

          final recoveryData =
              jsonDecode(recoveryCheck['result']?['value'] as String? ?? '{}');
          formResult['recovery_indicators'] =
              recoveryData['recovery_indicators'] ?? [];
          formResult['values_persisted'] =
              recoveryData['values_persisted'] ?? false;
          formResult['success'] = true;
        } catch (e) {
          formResult['success'] = false;
          formResult['error'] = e.toString();
        }

        results.add(formResult);
      }

      // Final restore if requested
      if (restoreAfter) {
        await cdp.sendCommand('Network.emulateNetworkConditions', {
          'offline': false,
          'latency': 0,
          'downloadThroughput': -1,
          'uploadThroughput': -1,
        });
      }

      return {
        'success': true,
        'forms_found': forms.length,
        'results': results,
      };
    } catch (e) {
      // Always try to restore network on error
      try {
        await cdp.sendCommand('Network.emulateNetworkConditions', {
          'offline': false,
          'latency': 0,
          'downloadThroughput': -1,
          'uploadThroughput': -1,
        });
      } catch (_) {}
      return {'success': false, 'error': e.toString()};
    }
  }

  String _buildInputSelector(dynamic input) {
    final id = input['id'] as String? ?? '';
    if (id.isNotEmpty) return '#${id.replaceAll("'", "\\'")}';
    final name = input['name'] as String? ?? '';
    if (name.isNotEmpty) return '[name="${name.replaceAll('"', '\\"')}"]';
    return '${input['tag'] ?? 'input'}[type="${input['type'] ?? 'text'}"]';
  }

  String _generateTestValue(dynamic input) {
    final type = (input['type'] as String? ?? 'text').toLowerCase();
    switch (type) {
      case 'email':
        return 'test@example.com';
      case 'password':
        return 'TestPassword123!';
      case 'tel':
        return '+1234567890';
      case 'number':
        return '42';
      case 'url':
        return 'https://example.com';
      case 'date':
        return '2024-01-15';
      case 'datetime-local':
        return '2024-01-15T10:30';
      case 'search':
      case 'text':
      default:
        return 'Test input value';
    }
  }

  /// Test app behavior during network transitions.
  Future<Map<String, dynamic>> _testNetworkTransitions(
      Map<String, dynamic> args) async {
    final cdp = _cdpDriver;
    if (cdp == null) {
      return {'success': false, 'error': 'CDP connection required'};
    }

    final scenarios = (args['scenarios'] as List<dynamic>?)?.cast<String>() ??
        ['offline_online', 'slow_3g'];

    final results = <Map<String, dynamic>>[];

    for (final scenario in scenarios) {
      final scenarioResult = <String, dynamic>{
        'scenario': scenario,
      };

      try {
        // Collect console errors during the test
        final consoleErrors = <String>[];
        void onConsoleError(Map<String, dynamic> params) {
          final entry = params['entry'] as Map<String, dynamic>?;
          if (entry != null &&
              (entry['level'] == 'error' || entry['level'] == 'warning')) {
            consoleErrors.add('${entry['level']}: ${entry['text'] ?? ''}');
          }
        }

        await cdp.sendCommand('Log.enable', {});
        cdp.onEvent('Log.entryAdded', onConsoleError);

        switch (scenario) {
          case 'offline_online':
            scenarioResult.addAll(await _runOfflineOnlineTest(cdp));
            break;
          case 'slow_3g':
          case 'fast_3g':
          case 'regular_4g':
          case 'wifi':
            scenarioResult.addAll(await _runThrottleTest(cdp, scenario));
            break;
          case 'intermittent':
            scenarioResult.addAll(await _runIntermittentTest(cdp));
            break;
          default:
            scenarioResult['error'] = 'Unknown scenario: $scenario';
        }

        cdp.removeEventListeners('Log.entryAdded');
        scenarioResult['console_errors'] = consoleErrors;
        scenarioResult['success'] = true;
      } catch (e) {
        scenarioResult['success'] = false;
        scenarioResult['error'] = e.toString();
      }

      results.add(scenarioResult);
    }

    // Restore normal network
    try {
      await cdp.sendCommand('Network.emulateNetworkConditions', {
        'offline': false,
        'latency': 0,
        'downloadThroughput': -1,
        'uploadThroughput': -1,
      });
    } catch (_) {}

    return {
      'success': true,
      'scenarios_tested': results.length,
      'results': results,
    };
  }

  Future<Map<String, dynamic>> _runOfflineOnlineTest(CdpDriver cdp) async {
    // Record initial page state
    final beforeState = await _getNetworkPageState(cdp);

    // Go offline for 5 seconds
    await cdp.sendCommand('Network.emulateNetworkConditions', {
      'offline': true,
      'latency': 0,
      'downloadThroughput': -1,
      'uploadThroughput': -1,
    });

    await Future.delayed(const Duration(seconds: 5));

    final offlineState = await _getNetworkPageState(cdp);

    // Restore network
    await cdp.sendCommand('Network.emulateNetworkConditions', {
      'offline': false,
      'latency': 0,
      'downloadThroughput': -1,
      'uploadThroughput': -1,
    });

    // Wait for recovery
    await Future.delayed(const Duration(seconds: 3));

    final afterState = await _getNetworkPageState(cdp);

    return {
      'before_state': beforeState,
      'offline_state': offlineState,
      'after_state': afterState,
      'auto_recovered': afterState['title'] == beforeState['title'] &&
          !(afterState['has_error_indicators'] as bool? ?? false),
    };
  }

  Future<Map<String, dynamic>> _runThrottleTest(
      CdpDriver cdp, String preset) async {
    final config = _networkPresets[preset]!;

    await cdp.sendCommand('Network.emulateNetworkConditions', {
      'offline': false,
      'latency': config['latency']!,
      'downloadThroughput': config['downloadThroughput']!,
      'uploadThroughput': config['uploadThroughput']!,
    });

    // Reload page and measure load time
    final sw = Stopwatch()..start();

    await cdp.sendCommand('Page.reload', {});
    // Wait for load event
    try {
      await cdp.call('Page.loadEventFired', {}).timeout(
          const Duration(seconds: 30),
          onTimeout: () => <String, dynamic>{});
    } catch (_) {
      // Fallback: just wait
      await Future.delayed(const Duration(seconds: 10));
    }

    sw.stop();

    // Restore normal
    await cdp.sendCommand('Network.emulateNetworkConditions', {
      'offline': false,
      'latency': 0,
      'downloadThroughput': -1,
      'uploadThroughput': -1,
    });

    final state = await _getNetworkPageState(cdp);

    return {
      'preset': preset,
      'config': config,
      'load_time_ms': sw.elapsedMilliseconds,
      'page_state': state,
    };
  }

  Future<Map<String, dynamic>> _runIntermittentTest(CdpDriver cdp) async {
    final random = Random();
    final transitions = <Map<String, dynamic>>[];
    var errorCount = 0;

    for (var i = 0; i < 6; i++) {
      final offline = i % 2 == 0;
      final durationMs = 2000 + random.nextInt(3000);

      await cdp.sendCommand('Network.emulateNetworkConditions', {
        'offline': offline,
        'latency': 0,
        'downloadThroughput': -1,
        'uploadThroughput': -1,
      });

      await Future.delayed(Duration(milliseconds: durationMs));

      final state = await _getNetworkPageState(cdp);
      if (state['has_error_indicators'] == true) errorCount++;

      transitions.add({
        'offline': offline,
        'duration_ms': durationMs,
        'page_state': state,
      });
    }

    // Restore
    await cdp.sendCommand('Network.emulateNetworkConditions', {
      'offline': false,
      'latency': 0,
      'downloadThroughput': -1,
      'uploadThroughput': -1,
    });

    await Future.delayed(const Duration(seconds: 2));

    return {
      'transitions': transitions,
      'total_transitions': transitions.length,
      'error_count': errorCount,
      'final_state': await _getNetworkPageState(cdp),
    };
  }

  Future<Map<String, dynamic>> _getNetworkPageState(CdpDriver cdp) async {
    final result = await cdp.call('Runtime.evaluate', {
      'expression': '''
(() => {
  const errorSelectors = ['.error', '[role="alert"]', '.alert-danger', '.alert-error', '.offline', '.no-connection'];
  const hasErrors = errorSelectors.some(sel => document.querySelector(sel) !== null);
  return JSON.stringify({
    title: document.title,
    url: location.href,
    has_error_indicators: hasErrors,
    body_text_length: document.body ? document.body.innerText.length : 0,
    visible_elements: document.querySelectorAll('*:not(script):not(style)').length,
  });
})()
''',
      'returnByValue': true,
    });
    return jsonDecode(result['result']?['value'] as String? ?? '{}')
        as Map<String, dynamic>;
  }

  /// Test request timeout handling.
  Future<Map<String, dynamic>> _testRequestTimeout(
      Map<String, dynamic> args) async {
    final cdp = _cdpDriver;
    if (cdp == null) {
      return {'success': false, 'error': 'CDP connection required'};
    }

    final delayMs = args['delay_ms'] as int? ?? 30000;
    final timeoutMs = args['timeout_ms'] as int? ?? 60000;

    final interceptedRequests = <Map<String, dynamic>>[];
    final pendingRequests = <String, DateTime>{};
    var timeoutDetected = false;

    try {
      // Enable Fetch domain to intercept requests
      await cdp.sendCommand('Fetch.enable', {
        'patterns': [
          {'urlPattern': '*', 'requestStage': 'Request'}
        ],
      });

      // Listen for paused requests and delay them
      cdp.onEvent('Fetch.requestPaused', (params) async {
        final requestId = params['requestId'] as String;
        final url = params['request']?['url'] as String? ?? '';

        // Skip data: and chrome: URLs
        if (url.startsWith('data:') || url.startsWith('chrome:')) {
          try {
            await cdp
                .sendCommand('Fetch.continueRequest', {'requestId': requestId});
          } catch (_) {}
          return;
        }

        pendingRequests[requestId] = DateTime.now();
        interceptedRequests.add({
          'url': url,
          'method': params['request']?['method'] ?? 'GET',
          'delayed_ms': delayMs,
        });

        // Delay before continuing the request
        await Future.delayed(Duration(milliseconds: delayMs));

        try {
          await cdp
              .sendCommand('Fetch.continueRequest', {'requestId': requestId});
        } catch (_) {
          // Request may have been cancelled
        }
        pendingRequests.remove(requestId);
      });

      // Wait for timeout period to observe behavior
      await Future.delayed(Duration(milliseconds: timeoutMs));

      // Check if app showed timeout indicators
      final timeoutCheck = await cdp.call('Runtime.evaluate', {
        'expression': '''
(() => {
  const text = document.body ? document.body.innerText.toLowerCase() : '';
  const timeoutPatterns = ['timeout', 'timed out', 'request failed', 'network error',
    'connection lost', 'try again', 'retry', 'slow connection', 'taking too long'];
  const found = timeoutPatterns.filter(p => text.includes(p));
  const errorEls = document.querySelectorAll('.error, [role="alert"], .alert, .toast, .snackbar');
  const errors = Array.from(errorEls).map(el => el.textContent.trim().substring(0, 200));
  return JSON.stringify({
    timeout_keywords_found: found,
    error_messages: errors,
    has_timeout_ui: found.length > 0 || errors.length > 0,
  });
})()
''',
        'returnByValue': true,
      });

      final timeoutData =
          jsonDecode(timeoutCheck['result']?['value'] as String? ?? '{}');
      timeoutDetected = timeoutData['has_timeout_ui'] == true;

      // Disable Fetch
      await cdp.sendCommand('Fetch.disable', {});
      cdp.removeEventListeners('Fetch.requestPaused');

      return {
        'success': true,
        'delay_ms': delayMs,
        'timeout_ms': timeoutMs,
        'requests_intercepted': interceptedRequests.length,
        'intercepted_requests': interceptedRequests.take(20).toList(),
        'timeout_ui_detected': timeoutDetected,
        'timeout_details': timeoutData,
      };
    } catch (e) {
      try {
        await cdp.sendCommand('Fetch.disable', {});
        cdp.removeEventListeners('Fetch.requestPaused');
      } catch (_) {}
      return {'success': false, 'error': e.toString()};
    }
  }
}
