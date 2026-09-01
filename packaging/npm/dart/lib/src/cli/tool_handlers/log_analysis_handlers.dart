part of '../server.dart';

extension _LogAnalysisHandlers on FlutterMcpServer {
  Future<dynamic> _handleLogAnalysisTools(
      String name, Map<String, dynamic> args) async {
    switch (name) {
      case 'analyze_console':
        return _analyzeConsole(args);
      case 'detect_memory_leak':
        return _detectMemoryLeak(args);
      case 'detect_render_issues':
        return _detectRenderIssues(args);
      default:
        return null;
    }
  }

  /// Intelligent analysis of console logs.
  Future<Map<String, dynamic>> _analyzeConsole(
      Map<String, dynamic> args) async {
    final cdp = _cdpDriver;
    if (cdp == null) {
      return {'success': false, 'error': 'CDP connection required'};
    }

    final durationMs = args['duration_ms'] as int? ?? 10000;
    final checks = (args['checks'] as List<dynamic>?)?.cast<String>() ??
        [
          'memory_leak',
          'deprecated_api',
          'repeated_errors',
          'unhandled_rejections'
        ];

    final logEntries = <Map<String, dynamic>>[];
    final exceptions = <Map<String, dynamic>>[];

    try {
      // Enable log and runtime domains
      await cdp.sendCommand('Log.enable', {});
      await cdp.sendCommand('Runtime.enable', {});

      // Get initial memory snapshot
      Map<String, dynamic>? initialMemory;
      if (checks.contains('memory_leak')) {
        initialMemory = await _getMemoryUsage(cdp);
      }

      // Inject PerformanceObserver for slow operations
      if (checks.contains('slow_operations')) {
        await cdp.call('Runtime.evaluate', {
          'expression': '''
window.__flutterSkillLongTasks = [];
if (typeof PerformanceObserver !== 'undefined') {
  const obs = new PerformanceObserver(list => {
    for (const entry of list.getEntries()) {
      if (entry.duration > 50) {
        window.__flutterSkillLongTasks.push({
          name: entry.name,
          duration: entry.duration,
          startTime: entry.startTime,
        });
      }
    }
  });
  try { obs.observe({entryTypes: ['longtask']}); } catch(e) {}
  window.__flutterSkillLongTaskObs = obs;
}
''',
          'returnByValue': true,
        });
      }

      // Collect log entries
      cdp.onEvent('Log.entryAdded', (params) {
        final entry = params['entry'] as Map<String, dynamic>?;
        if (entry != null) {
          logEntries.add({
            'level': entry['level'],
            'text': entry['text'] ?? '',
            'source': entry['source'] ?? '',
            'timestamp': entry['timestamp'],
          });
        }
      });

      // Collect runtime exceptions
      cdp.onEvent('Runtime.exceptionThrown', (params) {
        final details = params['exceptionDetails'] as Map<String, dynamic>?;
        if (details != null) {
          exceptions.add({
            'text': details['text'] ?? '',
            'description': details['exception']?['description'] ?? '',
            'line': details['lineNumber'],
            'column': details['columnNumber'],
            'url': details['url'] ?? '',
          });
        }
      });

      // Wait for the collection period
      await Future.delayed(Duration(milliseconds: durationMs));

      // Remove listeners
      cdp.removeEventListeners('Log.entryAdded');
      cdp.removeEventListeners('Runtime.exceptionThrown');

      // Analyze collected data
      final findings = <Map<String, dynamic>>[];

      // Memory leak check
      if (checks.contains('memory_leak') && initialMemory != null) {
        final finalMemory = await _getMemoryUsage(cdp);
        if (initialMemory['usedJSHeapSize'] != null &&
            finalMemory['usedJSHeapSize'] != null) {
          final initial = initialMemory['usedJSHeapSize'] as num;
          final current = finalMemory['usedJSHeapSize'] as num;
          if (initial > 0) {
            final growthPct = ((current - initial) / initial * 100);
            if (growthPct > 20) {
              findings.add({
                'type': 'memory_leak',
                'severity': 'warning',
                'message':
                    'Memory grew by ${growthPct.toStringAsFixed(1)}% during ${durationMs}ms observation',
                'details': {
                  'initial_bytes': initial,
                  'final_bytes': current,
                  'growth_percent': growthPct,
                },
              });
            }
          }
        }
      }

      // Deprecated API check
      if (checks.contains('deprecated_api')) {
        final deprecatedPatterns = RegExp(
            r'deprecated|will be removed|no longer supported|obsolete',
            caseSensitive: false);
        for (final entry in logEntries) {
          final text = entry['text'] as String? ?? '';
          if (deprecatedPatterns.hasMatch(text)) {
            findings.add({
              'type': 'deprecated_api',
              'severity': 'warning',
              'message':
                  text.length > 300 ? '${text.substring(0, 300)}...' : text,
              'source': entry['source'],
            });
          }
        }
      }

      // Repeated errors check
      if (checks.contains('repeated_errors')) {
        final errorCounts = <String, int>{};
        for (final entry in logEntries) {
          if (entry['level'] == 'error') {
            final text = entry['text'] as String? ?? '';
            final key = text.length > 100 ? text.substring(0, 100) : text;
            errorCounts[key] = (errorCounts[key] ?? 0) + 1;
          }
        }
        for (final e in errorCounts.entries) {
          if (e.value > 3) {
            findings.add({
              'type': 'repeated_errors',
              'severity': 'critical',
              'message': 'Error repeated ${e.value} times: ${e.key}',
              'count': e.value,
            });
          }
        }
      }

      // Unhandled rejections
      if (checks.contains('unhandled_rejections')) {
        for (final ex in exceptions) {
          findings.add({
            'type': 'unhandled_rejection',
            'severity': 'critical',
            'message': ex['text'] ?? ex['description'] ?? 'Unknown exception',
            'details': ex,
          });
        }
      }

      // Render warnings
      if (checks.contains('render_warnings')) {
        final renderPatterns = RegExp(
            r'Layout forced|Forced reflow|style recalculation|layout thrashing',
            caseSensitive: false);
        for (final entry in logEntries) {
          final text = entry['text'] as String? ?? '';
          if (renderPatterns.hasMatch(text)) {
            findings.add({
              'type': 'render_warning',
              'severity': 'warning',
              'message':
                  text.length > 300 ? '${text.substring(0, 300)}...' : text,
            });
          }
        }
      }

      // Slow operations
      if (checks.contains('slow_operations')) {
        final longTaskResult = await cdp.call('Runtime.evaluate', {
          'expression': 'JSON.stringify(window.__flutterSkillLongTasks || [])',
          'returnByValue': true,
        });
        final longTasks =
            jsonDecode(longTaskResult['result']?['value'] as String? ?? '[]')
                as List<dynamic>;
        for (final task in longTasks) {
          findings.add({
            'type': 'slow_operation',
            'severity':
                (task['duration'] as num? ?? 0) > 200 ? 'critical' : 'warning',
            'message':
                'Long task: ${(task['duration'] as num?)?.toStringAsFixed(1)}ms',
            'details': task,
          });
        }

        // Cleanup observer
        await cdp.call('Runtime.evaluate', {
          'expression': '''
if (window.__flutterSkillLongTaskObs) {
  window.__flutterSkillLongTaskObs.disconnect();
  delete window.__flutterSkillLongTaskObs;
  delete window.__flutterSkillLongTasks;
}
''',
          'returnByValue': true,
        });
      }

      return {
        'success': true,
        'duration_ms': durationMs,
        'total_log_entries': logEntries.length,
        'total_exceptions': exceptions.length,
        'findings_count': findings.length,
        'findings': findings,
        'summary': {
          'critical': findings.where((f) => f['severity'] == 'critical').length,
          'warning': findings.where((f) => f['severity'] == 'warning').length,
          'info': findings.where((f) => f['severity'] == 'info').length,
        },
      };
    } catch (e) {
      try {
        cdp.removeEventListeners('Log.entryAdded');
        cdp.removeEventListeners('Runtime.exceptionThrown');
      } catch (_) {}
      return {'success': false, 'error': e.toString()};
    }
  }

  Future<Map<String, dynamic>> _getMemoryUsage(CdpDriver cdp) async {
    final result = await cdp.call('Runtime.evaluate', {
      'expression': '''
JSON.stringify(performance.memory ? {
  usedJSHeapSize: performance.memory.usedJSHeapSize,
  totalJSHeapSize: performance.memory.totalJSHeapSize,
  jsHeapSizeLimit: performance.memory.jsHeapSizeLimit,
} : {})
''',
      'returnByValue': true,
    });
    return jsonDecode(result['result']?['value'] as String? ?? '{}')
        as Map<String, dynamic>;
  }

  /// Monitor memory usage over time to detect leaks.
  Future<Map<String, dynamic>> _detectMemoryLeak(
      Map<String, dynamic> args) async {
    final cdp = _cdpDriver;
    if (cdp == null) {
      return {'success': false, 'error': 'CDP connection required'};
    }

    final durationMs = args['duration_ms'] as int? ?? 30000;
    final intervalMs = args['interval_ms'] as int? ?? 5000;
    final actionBetween = args['action_between'] as String?;

    final snapshots = <Map<String, dynamic>>[];
    final iterations = (durationMs / intervalMs).ceil();

    try {
      for (var i = 0; i <= iterations; i++) {
        final mem = await _getMemoryUsage(cdp);
        mem['timestamp_ms'] = DateTime.now().millisecondsSinceEpoch;
        mem['iteration'] = i;
        snapshots.add(mem);

        if (i < iterations) {
          // Execute action between snapshots if specified
          if (actionBetween != null) {
            try {
              await _executeTool(actionBetween, {});
            } catch (_) {}
          }
          await Future.delayed(Duration(milliseconds: intervalMs));
        }
      }

      // Linear regression on usedJSHeapSize to detect growth trend
      final heapValues = snapshots
          .map((s) => (s['usedJSHeapSize'] as num?)?.toDouble())
          .whereType<double>()
          .toList();

      bool leakDetected = false;
      double growthRatePerSecond = 0;

      if (heapValues.length >= 2) {
        // Simple linear regression
        final n = heapValues.length;
        double sumX = 0, sumY = 0, sumXY = 0, sumX2 = 0;
        for (var i = 0; i < n; i++) {
          final x = i.toDouble();
          final y = heapValues[i];
          sumX += x;
          sumY += y;
          sumXY += x * y;
          sumX2 += x * x;
        }
        final slope = (n * sumXY - sumX * sumY) / (n * sumX2 - sumX * sumX);
        growthRatePerSecond = slope / (intervalMs / 1000);

        // Leak if consistent growth > 1KB/s
        final totalGrowth = heapValues.last - heapValues.first;
        final growthPct =
            heapValues.first > 0 ? (totalGrowth / heapValues.first * 100) : 0.0;
        leakDetected = growthPct > 10 && growthRatePerSecond > 1024;
      }

      return {
        'success': true,
        'snapshots': snapshots,
        'snapshot_count': snapshots.length,
        'duration_ms': durationMs,
        'interval_ms': intervalMs,
        'leak_detected': leakDetected,
        'growth_rate_bytes_per_second': growthRatePerSecond,
        'initial_heap_bytes': heapValues.isNotEmpty ? heapValues.first : null,
        'final_heap_bytes': heapValues.isNotEmpty ? heapValues.last : null,
        'total_growth_bytes':
            heapValues.length >= 2 ? heapValues.last - heapValues.first : 0,
      };
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Detect rendering issues via Performance domain.
  Future<Map<String, dynamic>> _detectRenderIssues(
      Map<String, dynamic> args) async {
    final cdp = _cdpDriver;
    if (cdp == null) {
      return {'success': false, 'error': 'CDP connection required'};
    }

    final durationMs = args['duration_ms'] as int? ?? 10000;

    try {
      await cdp.call('Performance.enable', {});

      // Inject PerformanceObservers for longtask and layout-shift
      await cdp.call('Runtime.evaluate', {
        'expression': '''
window.__flutterSkillRenderData = {longTasks: [], layoutShifts: [], measures: []};
if (typeof PerformanceObserver !== 'undefined') {
  try {
    const ltObs = new PerformanceObserver(list => {
      for (const entry of list.getEntries()) {
        window.__flutterSkillRenderData.longTasks.push({
          name: entry.name, duration: entry.duration, startTime: entry.startTime
        });
      }
    });
    ltObs.observe({entryTypes: ['longtask']});
    window.__flutterSkillRenderObs1 = ltObs;
  } catch(e) {}

  try {
    const lsObs = new PerformanceObserver(list => {
      for (const entry of list.getEntries()) {
        window.__flutterSkillRenderData.layoutShifts.push({
          value: entry.value, hadRecentInput: entry.hadRecentInput, startTime: entry.startTime
        });
      }
    });
    lsObs.observe({entryTypes: ['layout-shift']});
    window.__flutterSkillRenderObs2 = lsObs;
  } catch(e) {}
}
// Collect performance measures
try {
  const measures = performance.getEntriesByType('measure');
  window.__flutterSkillRenderData.measures = measures.map(m => ({
    name: m.name, duration: m.duration, startTime: m.startTime
  }));
} catch(e) {}
''',
        'returnByValue': true,
      });

      // Wait for observation period
      await Future.delayed(Duration(milliseconds: durationMs));

      // Collect results
      final dataResult = await cdp.call('Runtime.evaluate', {
        'expression': 'JSON.stringify(window.__flutterSkillRenderData || {})',
        'returnByValue': true,
      });

      final data = jsonDecode(dataResult['result']?['value'] as String? ?? '{}')
          as Map<String, dynamic>;

      final longTasks = (data['longTasks'] as List<dynamic>?) ?? [];
      final layoutShifts = (data['layoutShifts'] as List<dynamic>?) ?? [];
      final measures = (data['measures'] as List<dynamic>?) ?? [];

      // Get Performance metrics
      final metricsResult = await cdp.call('Performance.getMetrics', {});
      final metrics = (metricsResult['metrics'] as List<dynamic>?)
              ?.map((m) => {
                    'name': m['name'],
                    'value': m['value'],
                  })
              .toList() ??
          [];

      // Calculate CLS (Cumulative Layout Shift)
      double cls = 0;
      for (final shift in layoutShifts) {
        if (shift['hadRecentInput'] != true) {
          cls += (shift['value'] as num?)?.toDouble() ?? 0;
        }
      }

      // Build recommendations
      final recommendations = <String>[];
      if (longTasks.isNotEmpty) {
        recommendations.add(
            '${longTasks.length} long tasks detected (>50ms). Consider breaking up work or using requestIdleCallback.');
      }
      if (cls > 0.1) {
        recommendations.add(
            'CLS is ${cls.toStringAsFixed(3)} (threshold: 0.1). Add explicit dimensions to images/ads/dynamic content.');
      }
      if (cls > 0.25) {
        recommendations.add(
            'CLS is very high (${cls.toStringAsFixed(3)}). This significantly impacts user experience.');
      }

      // Cleanup
      await cdp.call('Runtime.evaluate', {
        'expression': '''
if (window.__flutterSkillRenderObs1) window.__flutterSkillRenderObs1.disconnect();
if (window.__flutterSkillRenderObs2) window.__flutterSkillRenderObs2.disconnect();
delete window.__flutterSkillRenderData;
delete window.__flutterSkillRenderObs1;
delete window.__flutterSkillRenderObs2;
''',
        'returnByValue': true,
      });

      await cdp.call('Performance.disable', {});

      return {
        'success': true,
        'duration_ms': durationMs,
        'long_tasks': longTasks,
        'long_task_count': longTasks.length,
        'layout_shifts': layoutShifts,
        'cumulative_layout_shift': cls,
        'cls_rating': cls <= 0.1
            ? 'good'
            : cls <= 0.25
                ? 'needs_improvement'
                : 'poor',
        'measures': measures.take(50).toList(),
        'performance_metrics': metrics,
        'recommendations': recommendations,
      };
    } catch (e) {
      try {
        await cdp.call('Performance.disable', {});
      } catch (_) {}
      return {'success': false, 'error': e.toString()};
    }
  }
}
