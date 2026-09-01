part of '../server.dart';

extension _CoverageHandlers on FlutterMcpServer {
  /// Handle test coverage tracking tools.
  /// Returns null if the tool is not handled by this group.
  Future<dynamic> _handleCoverageTools(
      String name, Map<String, dynamic> args) async {
    switch (name) {
      case 'coverage_start':
        return _handleCoverageStart(args);
      case 'coverage_stop':
        return _handleCoverageStop(args);
      case 'coverage_report':
        return _handleCoverageReport(args);
      case 'coverage_gaps':
        return _handleCoverageGaps(args);
      default:
        return null;
    }
  }

  /// Record a page visit for coverage tracking.
  // ignore: unused_element
  void _coverageRecordPage(String url) {
    if (_coverageTracking) {
      _coveragePages.add(url);
    }
  }

  /// Record an element interaction for coverage tracking.
  // ignore: unused_element
  void _coverageRecordElement(String element) {
    if (_coverageTracking) {
      _coverageElements.add(element);
    }
  }

  /// Record an action for coverage tracking.
  // ignore: unused_element
  void _coverageRecordAction(String toolName, Map<String, dynamic> args) {
    if (_coverageTracking) {
      _coverageActions.add({
        'tool': toolName,
        'args': Map<String, dynamic>.from(args),
        'timestamp': DateTime.now().toIso8601String(),
      });

      // Extract element identifiers from args
      final key = args['key'] as String?;
      final text = args['text'] as String?;
      final selector = args['selector'] as String?;
      final ref = args['ref'] as String?;
      if (key != null) _coverageElements.add('key:$key');
      if (selector != null) _coverageElements.add('selector:$selector');
      if (ref != null) _coverageElements.add('ref:$ref');
      if (text != null && ['tap', 'assert_visible'].contains(toolName)) {
        _coverageElements.add('text:$text');
      }
    }
  }

  Future<Map<String, dynamic>> _handleCoverageStart(
      Map<String, dynamic> args) async {
    _coverageTracking = true;
    _coveragePages.clear();
    _coverageElements.clear();
    _coverageActions.clear();
    return {
      'success': true,
      'message':
          'Coverage tracking started. All page visits, element interactions, and actions will be recorded.',
    };
  }

  Future<Map<String, dynamic>> _handleCoverageStop(
      Map<String, dynamic> args) async {
    _coverageTracking = false;
    return {
      'success': true,
      'summary': {
        'pages_visited': _coveragePages.length,
        'elements_interacted': _coverageElements.length,
        'actions_performed': _coverageActions.length,
        'pages': _coveragePages.toList(),
        'elements': _coverageElements.toList(),
        'action_types': _coverageActions.map((a) => a['tool']).toSet().toList(),
      },
    };
  }

  Future<Map<String, dynamic>> _handleCoverageReport(
      Map<String, dynamic> args) async {
    final format = args['format'] as String? ?? 'json';
    final savePath = args['save_path'] as String?;

    // Try to get all interactive elements for coverage calculation
    List<Map<String, dynamic>> allElements = [];
    try {
      final client = _getClient(args);
      if (client != null) {
        final structured = await client.getInteractiveElementsStructured();
        if (structured['elements'] is List) {
          allElements =
              (structured['elements'] as List).cast<Map<String, dynamic>>();
        }
      }
    } catch (_) {
      // Ignore - we may not have a connection
    }

    final totalElements = allElements.length;
    final testedCount = _coverageElements.length;
    final coveragePercent = totalElements > 0
        ? (testedCount / totalElements * 100).toStringAsFixed(1)
        : 'N/A';

    final report = {
      'coverage_percent': coveragePercent,
      'total_interactive_elements': totalElements,
      'tested_elements': testedCount,
      'pages_visited': _coveragePages.length,
      'actions_performed': _coverageActions.length,
      'pages': _coveragePages.toList(),
      'tested_element_list': _coverageElements.toList(),
      'action_breakdown': _actionBreakdown(),
      'all_elements': allElements.map((e) {
        final key = (e['key'] ?? e['ref'] ?? e['selector'] ?? '').toString();
        return {
          'identifier': key,
          'type': e['type'] ?? e['widget'] ?? 'unknown',
          'tested': _coverageElements.contains('key:$key') ||
              _coverageElements.contains('ref:$key') ||
              _coverageElements.contains('selector:$key'),
        };
      }).toList(),
    };

    if (format == 'html') {
      final html = _generateCoverageHtml(report);
      if (savePath != null) {
        final file = File(savePath);
        await file.parent.create(recursive: true);
        await file.writeAsString(html);
        return {'success': true, 'path': savePath, 'format': 'html'};
      }
      return {'success': true, 'html': html};
    }

    if (savePath != null) {
      final file = File(savePath);
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(report));
      return {'success': true, 'path': savePath, 'format': 'json'};
    }

    return {'success': true, 'report': report};
  }

  Map<String, int> _actionBreakdown() {
    final breakdown = <String, int>{};
    for (final action in _coverageActions) {
      final tool = action['tool'] as String? ?? 'unknown';
      breakdown[tool] = (breakdown[tool] ?? 0) + 1;
    }
    return breakdown;
  }

  Future<Map<String, dynamic>> _handleCoverageGaps(
      Map<String, dynamic> args) async {
    // Get all interactive elements
    List<Map<String, dynamic>> allElements = [];
    try {
      final client = _getClient(args);
      if (client != null) {
        final structured = await client.getInteractiveElementsStructured();
        if (structured['elements'] is List) {
          allElements =
              (structured['elements'] as List).cast<Map<String, dynamic>>();
        }
      }
    } catch (_) {
      // Ignore
    }

    // Find untested elements
    final untestedElements = <Map<String, dynamic>>[];
    for (final el in allElements) {
      final key = el['key'] ?? el['ref'] ?? el['selector'] ?? '';
      final tested = _coverageElements.contains('key:$key') ||
          _coverageElements.contains('ref:$key') ||
          _coverageElements.contains('selector:$key') ||
          _coverageElements.contains('text:$key');
      if (!tested) {
        untestedElements.add({
          'identifier': key,
          'type': el['type'] ?? el['widget'] ?? 'unknown',
          'label': el['label'] ?? el['text'] ?? '',
        });
      }
    }

    // Determine which action types have NOT been used
    final allActionTypes = {
      'tap',
      'enter_text',
      'swipe',
      'long_press',
      'scroll',
      'drag'
    };
    final usedActionTypes =
        _coverageActions.map((a) => a['tool'] as String).toSet();
    final missingActionTypes = allActionTypes.difference(usedActionTypes);

    // Generate suggested test cases
    final suggestions = <String>[];
    for (final el in untestedElements.take(10)) {
      final id = el['identifier'];
      final type = el['type'];
      if (type.toString().toLowerCase().contains('button') ||
          type.toString().toLowerCase().contains('tap')) {
        suggestions.add('Tap on "$id" ($type) and verify behavior');
      } else if (type.toString().toLowerCase().contains('text') ||
          type.toString().toLowerCase().contains('field') ||
          type.toString().toLowerCase().contains('input')) {
        suggestions.add('Enter text in "$id" ($type) and validate');
      } else {
        suggestions.add('Interact with "$id" ($type) and verify state');
      }
    }
    for (final action in missingActionTypes) {
      suggestions.add('Add test cases using "$action" action');
    }

    return {
      'success': true,
      'untested_elements': untestedElements,
      'untested_count': untestedElements.length,
      'total_elements': allElements.length,
      'missing_action_types': missingActionTypes.toList(),
      'used_action_types': usedActionTypes.toList(),
      'suggestions': suggestions,
      'pages_visited': _coveragePages.toList(),
    };
  }

  String _generateCoverageHtml(Map<String, dynamic> report) {
    final buf = StringBuffer();
    buf.writeln('<!DOCTYPE html><html><head><meta charset="utf-8">');
    buf.writeln('<title>Test Coverage Report</title>');
    buf.writeln('<style>');
    buf.writeln(
        'body { font-family: -apple-system, sans-serif; margin: 2em; }');
    buf.writeln('table { border-collapse: collapse; width: 100%; }');
    buf.writeln(
        'th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }');
    buf.writeln('th { background: #f5f5f5; }');
    buf.writeln('.tested { color: green; } .untested { color: red; }');
    buf.writeln('.summary { display: flex; gap: 2em; margin: 1em 0; }');
    buf.writeln(
        '.stat { background: #f0f0f0; padding: 1em; border-radius: 8px; }');
    buf.writeln('.stat h3 { margin: 0; }');
    buf.writeln('</style></head><body>');
    buf.writeln('<h1>Test Coverage Report</h1>');
    buf.writeln('<div class="summary">');
    buf.writeln(
        '<div class="stat"><h3>Coverage</h3><p>${report['coverage_percent']}%</p></div>');
    buf.writeln(
        '<div class="stat"><h3>Pages Visited</h3><p>${report['pages_visited']}</p></div>');
    buf.writeln(
        '<div class="stat"><h3>Elements Tested</h3><p>${report['tested_elements']}</p></div>');
    buf.writeln(
        '<div class="stat"><h3>Actions</h3><p>${report['actions_performed']}</p></div>');
    buf.writeln('</div>');

    // Elements table
    final elements = report['all_elements'] as List? ?? [];
    if (elements.isNotEmpty) {
      buf.writeln(
          '<h2>Elements</h2><table><tr><th>Identifier</th><th>Type</th><th>Status</th></tr>');
      for (final el in elements) {
        final tested = el['tested'] == true;
        final cls = tested ? 'tested' : 'untested';
        buf.writeln(
            '<tr><td>${el['identifier']}</td><td>${el['type']}</td><td class="$cls">${tested ? '✓ Tested' : '✗ Untested'}</td></tr>');
      }
      buf.writeln('</table>');
    }

    // Actions breakdown
    final breakdown = report['action_breakdown'] as Map? ?? {};
    if (breakdown.isNotEmpty) {
      buf.writeln(
          '<h2>Action Breakdown</h2><table><tr><th>Action</th><th>Count</th></tr>');
      for (final entry in breakdown.entries) {
        buf.writeln('<tr><td>${entry.key}</td><td>${entry.value}</td></tr>');
      }
      buf.writeln('</table>');
    }

    buf.writeln('</body></html>');
    return buf.toString();
  }
}
