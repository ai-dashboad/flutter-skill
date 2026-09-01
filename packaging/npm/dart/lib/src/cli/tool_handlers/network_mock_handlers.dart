part of '../server.dart';

/// Network mock rules and recordings storage.
class _NetworkMockState {
  final List<_MockRule> rules = [];
  final Map<String, _NetworkRecording> recordings = {};
  bool fetchEnabled = false;
  String? activeRecordingId;
}

class _MockRule {
  final String urlPattern;
  final String? method;
  final int status;
  final String body;
  final Map<String, String> headers;
  final int delayMs;

  _MockRule({
    required this.urlPattern,
    this.method,
    this.status = 200,
    this.body = '',
    this.headers = const {},
    this.delayMs = 0,
  });

  bool matches(String url, String requestMethod) {
    // Check method
    if (method != null &&
        method!.toUpperCase() != requestMethod.toUpperCase()) {
      return false;
    }
    // Glob-style matching: * matches anything
    final pattern = urlPattern.replaceAll('.', r'\.').replaceAll('*', '.*');
    return RegExp('^$pattern\$').hasMatch(url);
  }
}

class _NetworkRecording {
  final String id;
  final String? filterUrl;
  final List<_RecordedEntry> entries = [];
  final DateTime startedAt = DateTime.now();

  _NetworkRecording({required this.id, this.filterUrl});
}

class _RecordedEntry {
  final String url;
  final String method;
  final int status;
  final Map<String, String> responseHeaders;
  final String responseBody;

  _RecordedEntry({
    required this.url,
    required this.method,
    required this.status,
    required this.responseHeaders,
    required this.responseBody,
  });
}

extension _NetworkMockHandlers on FlutterMcpServer {
  // Access shared mock state (stored on the server instance)
  _NetworkMockState get _mockState {
    _networkMockState ??= _NetworkMockState();
    return _networkMockState!;
  }

  Future<dynamic> _handleNetworkMockTools(
      String name, Map<String, dynamic> args) async {
    switch (name) {
      case 'mock_api':
        return _mockApi(args);
      case 'mock_clear':
        return _mockClear();
      case 'record_network':
        return _recordNetwork(args);
      case 'replay_network':
        return _replayNetwork(args);
      default:
        return null;
    }
  }

  Future<Map<String, dynamic>> _mockApi(Map<String, dynamic> args) async {
    final cdp = _cdpDriver;
    if (cdp == null) {
      return {'success': false, 'error': 'No CDP connection'};
    }

    final urlPattern = args['url_pattern'] as String?;
    if (urlPattern == null) {
      return {
        'success': false,
        'error':
            'url_pattern parameter is required. Provide a URL pattern to mock (e.g., "*api/users*").'
      };
    }

    final rule = _MockRule(
      urlPattern: urlPattern,
      method: args['method'] as String?,
      status: (args['status'] as int?) ?? 200,
      body: args['body'] as String? ?? '',
      headers: (args['headers'] as Map<String, dynamic>?)
              ?.map((k, v) => MapEntry(k, v.toString())) ??
          {},
      delayMs: (args['delay_ms'] as int?) ?? 0,
    );
    _mockState.rules.add(rule);

    // Enable Fetch domain if not already
    await _ensureFetchEnabled(cdp);

    return {
      'success': true,
      'mock_count': _mockState.rules.length,
      'url_pattern': urlPattern,
      'status': rule.status,
    };
  }

  Future<Map<String, dynamic>> _mockClear() async {
    final cdp = _cdpDriver;
    _mockState.rules.clear();

    if (cdp != null && _mockState.fetchEnabled) {
      try {
        await cdp.sendCommand('Fetch.disable');
        _mockState.fetchEnabled = false;
      } catch (_) {}
    }

    return {'success': true, 'message': 'All mocks cleared'};
  }

  Future<Map<String, dynamic>> _recordNetwork(Map<String, dynamic> args) async {
    final cdp = _cdpDriver;
    if (cdp == null) {
      return {'success': false, 'error': 'No CDP connection'};
    }

    final filterUrl = args['filter_url'] as String?;
    final id = 'rec_${DateTime.now().millisecondsSinceEpoch}';
    final recording = _NetworkRecording(id: id, filterUrl: filterUrl);
    _mockState.recordings[id] = recording;
    _mockState.activeRecordingId = id;

    // Enable Network domain (usually already enabled)
    await cdp.sendCommand('Network.enable');

    // Listen for responses
    cdp.onEvent('Network.responseReceived', (params) {
      if (_mockState.activeRecordingId != id) return;
      final response = params['response'] as Map<String, dynamic>? ?? {};
      final url = response['url']?.toString() ?? '';
      final status = response['status'] as int? ?? 0;
      final method = params['type']?.toString() ?? 'GET';

      if (filterUrl != null && !url.contains(filterUrl)) return;

      final headers = <String, String>{};
      final rawHeaders = response['headers'] as Map<String, dynamic>? ?? {};
      rawHeaders.forEach((k, v) => headers[k] = v.toString());

      // Store request ID for body retrieval
      final requestId = params['requestId']?.toString();
      if (requestId != null) {
        // Try to get response body asynchronously
        cdp.sendCommand('Network.getResponseBody',
            {'requestId': requestId}).then((bodyResult) {
          final body = bodyResult['body']?.toString() ?? '';
          recording.entries.add(_RecordedEntry(
            url: url,
            method: method,
            status: status,
            responseHeaders: headers,
            responseBody: body,
          ));
        }).catchError((_) {
          // Body might not be available yet, store without it
          recording.entries.add(_RecordedEntry(
            url: url,
            method: method,
            status: status,
            responseHeaders: headers,
            responseBody: '',
          ));
        });
      }
    });

    return {
      'success': true,
      'recording_id': id,
      'message':
          'Recording started${filterUrl != null ? ' (filter: $filterUrl)' : ''}',
    };
  }

  Future<Map<String, dynamic>> _replayNetwork(Map<String, dynamic> args) async {
    final cdp = _cdpDriver;
    if (cdp == null) {
      return {'success': false, 'error': 'No CDP connection'};
    }

    final recordingId = args['recording_id'] as String?;
    if (recordingId == null) {
      return {
        'success': false,
        'error':
            'recording_id parameter is required. Provide the ID from a previous network recording.'
      };
    }

    final recording = _mockState.recordings[recordingId];
    if (recording == null) {
      return {
        'success': false,
        'error': 'Recording not found: $recordingId',
        'available': _mockState.recordings.keys.toList(),
      };
    }

    // Stop active recording if this one is playing
    if (_mockState.activeRecordingId == recordingId) {
      _mockState.activeRecordingId = null;
    }

    // Convert recorded entries to mock rules
    var addedCount = 0;
    for (final entry in recording.entries) {
      _mockState.rules.add(_MockRule(
        urlPattern: entry.url,
        method: entry.method,
        status: entry.status,
        body: entry.responseBody,
        headers: entry.responseHeaders,
      ));
      addedCount++;
    }

    // Enable Fetch domain for interception
    await _ensureFetchEnabled(cdp);

    return {
      'success': true,
      'replayed_entries': addedCount,
      'recording_id': recordingId,
    };
  }

  Future<void> _ensureFetchEnabled(CdpDriver cdp) async {
    if (_mockState.fetchEnabled) return;

    await cdp.sendCommand('Fetch.enable', {
      'patterns': [
        {'urlPattern': '*', 'requestStage': 'Request'},
      ],
    });
    _mockState.fetchEnabled = true;

    // Handle paused requests
    cdp.onEvent('Fetch.requestPaused', (params) async {
      final requestId = params['requestId'] as String? ?? '';
      final url = params['request']?['url']?.toString() ?? '';
      final method = params['request']?['method']?.toString() ?? 'GET';

      // Find matching mock rule
      _MockRule? matchedRule;
      for (final rule in _mockState.rules) {
        if (rule.matches(url, method)) {
          matchedRule = rule;
          break;
        }
      }

      if (matchedRule != null) {
        // Apply delay if configured
        if (matchedRule.delayMs > 0) {
          await Future.delayed(Duration(milliseconds: matchedRule.delayMs));
        }

        // Build response headers
        final responseHeaders = <Map<String, String>>[
          {'name': 'Content-Type', 'value': 'application/json'},
          ...matchedRule.headers.entries
              .map((e) => {'name': e.key, 'value': e.value}),
        ];

        // Fulfill with mock response
        try {
          await cdp.sendCommand('Fetch.fulfillRequest', {
            'requestId': requestId,
            'responseCode': matchedRule.status,
            'responseHeaders': responseHeaders,
            'body': base64.encode(utf8.encode(matchedRule.body)),
          });
        } catch (_) {}
      } else {
        // Continue normally
        try {
          await cdp.sendCommand('Fetch.continueRequest', {
            'requestId': requestId,
          });
        } catch (_) {}
      }
    });
  }
}
