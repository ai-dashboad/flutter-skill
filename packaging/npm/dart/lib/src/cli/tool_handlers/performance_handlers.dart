part of '../server.dart';

extension _PerformanceHandlers on FlutterMcpServer {
  /// Performance monitoring tools
  /// Returns null if the tool is not handled.
  Future<dynamic> _handlePerformanceTools(
      String name, Map<String, dynamic> args) async {
    if (name == 'perf_start') {
      return _handlePerfStart();
    }
    if (name == 'perf_stop') {
      return _handlePerfStop();
    }
    if (name == 'perf_report') {
      return _handlePerfReport(args);
    }
    return null;
  }

  Future<Map<String, dynamic>> _handlePerfStart() async {
    if (_perfCollecting) {
      return {
        'success': false,
        'error': 'Performance collection already in progress'
      };
    }

    _perfCollecting = true;
    _perfStartTime = DateTime.now();
    _perfMetricSnapshots.clear();

    final cdp = _cdpDriver;
    if (cdp != null) {
      try {
        // Enable performance domain
        await cdp.call('Performance.enable', {});

        // Start collecting performance entries via JS
        await cdp.call('Runtime.evaluate', {
          'expression': '''
            window.__perfEntries = [];
            window.__perfObserver = new PerformanceObserver((list) => {
              window.__perfEntries.push(...list.getEntries().map(e => ({
                name: e.name,
                entryType: e.entryType,
                startTime: e.startTime,
                duration: e.duration,
                value: e.value,
              })));
            });
            window.__perfObserver.observe({
              entryTypes: ['paint', 'largest-contentful-paint', 'layout-shift',
                           'resource', 'navigation', 'longtask']
            });

            // FPS counter
            window.__fpsFrames = 0;
            window.__fpsStart = performance.now();
            window.__fpsRunning = true;
            function __countFrame() {
              if (!window.__fpsRunning) return;
              window.__fpsFrames++;
              requestAnimationFrame(__countFrame);
            }
            requestAnimationFrame(__countFrame);
            'perf_started'
          ''',
          'returnByValue': true,
        });

        // Take initial metrics snapshot
        final metrics = await cdp.call('Performance.getMetrics', {});
        {
          _perfMetricSnapshots.add({
            'timestamp': DateTime.now().toIso8601String(),
            'type': 'start',
            'metrics': metrics['metrics'],
          });
        }
      } catch (e) {
        // Continue even if some CDP calls fail
      }
    } else if (_client is BridgeDriver) {
      // Bridge mode: start via bridge performance methods
      try {
        await (_client as BridgeDriver).callTool('get_performance', {});
      } catch (_) {}
    }

    return {
      'success': true,
      'message': 'Performance collection started',
      'start_time': _perfStartTime!.toIso8601String(),
      'mode': _cdpDriver != null
          ? 'cdp'
          : (_client is BridgeDriver ? 'bridge' : 'limited'),
    };
  }

  Future<Map<String, dynamic>> _handlePerfStop() async {
    if (!_perfCollecting) {
      return {
        'success': false,
        'error': 'No performance collection in progress'
      };
    }

    _perfCollecting = false;
    final duration = _perfStartTime != null
        ? DateTime.now().difference(_perfStartTime!).inMilliseconds
        : 0;

    final summary = <String, dynamic>{
      'duration_ms': duration,
    };

    final cdp = _cdpDriver;
    if (cdp != null) {
      try {
        // Get final metrics
        final metrics = await cdp.call('Performance.getMetrics', {});
        {
          _perfMetricSnapshots.add({
            'timestamp': DateTime.now().toIso8601String(),
            'type': 'stop',
            'metrics': metrics['metrics'],
          });
          summary['chrome_metrics'] = metrics['metrics'];
        }

        // Get collected performance entries and FPS
        final entriesResult = await cdp.call('Runtime.evaluate', {
          'expression': '''
            (function() {
              window.__fpsRunning = false;
              const elapsed = (performance.now() - window.__fpsStart) / 1000;
              const fps = elapsed > 0 ? window.__fpsFrames / elapsed : 0;
              if (window.__perfObserver) window.__perfObserver.disconnect();
              return JSON.stringify({
                fps: Math.round(fps * 10) / 10,
                totalFrames: window.__fpsFrames,
                elapsedSeconds: Math.round(elapsed * 100) / 100,
                entries: window.__perfEntries || [],
              });
            })()
          ''',
          'returnByValue': true,
        });

        final entriesJson = (entriesResult['result']
            as Map<String, dynamic>?)?['value'] as String?;
        if (entriesJson != null) {
          final data = jsonDecode(entriesJson) as Map<String, dynamic>;
          summary['fps'] = data['fps'];
          summary['total_frames'] = data['totalFrames'];
          summary['elapsed_seconds'] = data['elapsedSeconds'];

          final entries = data['entries'] as List<dynamic>? ?? [];

          // Extract key metrics
          double cls = 0;
          double? fcp;
          double? lcp;
          int networkRequests = 0;

          for (final entry in entries) {
            final entryType = entry['entryType'] as String? ?? '';
            switch (entryType) {
              case 'layout-shift':
                cls += (entry['value'] as num?)?.toDouble() ?? 0;
                break;
              case 'paint':
                if (entry['name'] == 'first-contentful-paint') {
                  fcp = (entry['startTime'] as num?)?.toDouble();
                }
                break;
              case 'largest-contentful-paint':
                lcp = (entry['startTime'] as num?)?.toDouble();
                break;
              case 'resource':
                networkRequests++;
                break;
            }
          }

          summary['cls'] = (cls * 1000).round() / 1000;
          if (fcp != null) summary['fcp_ms'] = fcp.round();
          if (lcp != null) summary['lcp_ms'] = lcp.round();
          summary['network_requests'] = networkRequests;
          summary['performance_entries_count'] = entries.length;
        }

        // Disable performance domain
        await cdp.call('Performance.disable', {});
      } catch (e) {
        summary['error'] = 'Failed to collect final metrics: $e';
      }
    } else if (_client is BridgeDriver) {
      try {
        final bridge = _client as BridgeDriver;
        final frameStats = await bridge.callTool('get_frame_stats', {});
        final memStats = await bridge.callTool('get_memory_stats', {});
        summary['frame_stats'] = frameStats;
        summary['memory_stats'] = memStats;
      } catch (e) {
        summary['bridge_error'] = e.toString();
      }
    }

    return {
      'success': true,
      'summary': summary,
    };
  }

  Future<Map<String, dynamic>> _handlePerfReport(
      Map<String, dynamic> args) async {
    final format = args['format'] as String? ?? 'json';
    final savePath = args['save_path'] as String?;

    // First stop collection if still running
    Map<String, dynamic>? stopResult;
    if (_perfCollecting) {
      stopResult = await _handlePerfStop();
    }

    final summary = stopResult?['summary'] as Map<String, dynamic>? ?? {};

    // Build warnings
    final warnings = <Map<String, dynamic>>[];

    final fps = summary['fps'] as num?;
    if (fps != null && fps < 30) {
      warnings.add({
        'metric': 'FPS',
        'value': fps,
        'threshold': 30,
        'severity': 'high',
        'recommendation': 'FPS is below 30. Check for expensive layouts, '
            'heavy paint operations, or excessive widget rebuilds.',
      });
    }

    final cls = summary['cls'] as num?;
    if (cls != null && cls > 0.25) {
      warnings.add({
        'metric': 'CLS',
        'value': cls,
        'threshold': 0.25,
        'severity': 'high',
        'recommendation': 'Cumulative Layout Shift exceeds 0.25. '
            'Ensure images have explicit dimensions and avoid dynamic content insertion above the fold.',
      });
    }

    final lcp = summary['lcp_ms'] as num?;
    if (lcp != null && lcp > 2500) {
      warnings.add({
        'metric': 'LCP',
        'value': '${lcp}ms',
        'threshold': '2500ms',
        'severity': 'medium',
        'recommendation': 'Largest Contentful Paint exceeds 2.5s. '
            'Optimize largest visible element loading — consider lazy loading, image compression, or preloading.',
      });
    }

    final fcp = summary['fcp_ms'] as num?;
    if (fcp != null && fcp > 1800) {
      warnings.add({
        'metric': 'FCP',
        'value': '${fcp}ms',
        'threshold': '1800ms',
        'severity': 'medium',
        'recommendation': 'First Contentful Paint exceeds 1.8s. '
            'Reduce initial bundle size and defer non-critical resources.',
      });
    }

    final report = {
      'summary': summary,
      'warnings': warnings,
      'warnings_count': warnings.length,
      'snapshots': _perfMetricSnapshots,
      'generated_at': DateTime.now().toIso8601String(),
      'score': _calculatePerfScore(summary),
    };

    String output;
    if (format == 'html') {
      output = _generateHtmlReport(report);
    } else {
      output = const JsonEncoder.withIndent('  ').convert(report);
    }

    if (savePath != null) {
      final file = File(savePath);
      await file.parent.create(recursive: true);
      await file.writeAsString(output);
      return {
        'success': true,
        'report': report,
        'saved_to': savePath,
        'format': format,
      };
    }

    return {
      'success': true,
      'report': report,
      'format': format,
    };
  }

  String _calculatePerfScore(Map<String, dynamic> summary) {
    int score = 100;
    final fps = summary['fps'] as num?;
    if (fps != null) {
      if (fps < 20) {
        score -= 40;
      } else if (fps < 30) {
        score -= 25;
      } else if (fps < 50) {
        score -= 10;
      }
    }
    final cls = summary['cls'] as num?;
    if (cls != null) {
      if (cls > 0.25) {
        score -= 25;
      } else if (cls > 0.1) {
        score -= 10;
      }
    }
    final lcp = summary['lcp_ms'] as num?;
    if (lcp != null) {
      if (lcp > 4000) {
        score -= 25;
      } else if (lcp > 2500) {
        score -= 15;
      }
    }
    if (score < 0) score = 0;
    if (score >= 90) return 'excellent ($score/100)';
    if (score >= 70) return 'good ($score/100)';
    if (score >= 50) return 'needs improvement ($score/100)';
    return 'poor ($score/100)';
  }

  String _generateHtmlReport(Map<String, dynamic> report) {
    final summary = report['summary'] as Map<String, dynamic>? ?? {};
    final warnings = report['warnings'] as List<dynamic>? ?? [];
    final score = report['score'] as String? ?? 'unknown';

    final buf = StringBuffer();
    buf.writeln('<!DOCTYPE html>');
    buf.writeln('<html><head><title>Performance Report</title>');
    buf.writeln('<style>');
    buf.writeln(
        'body { font-family: -apple-system, sans-serif; max-width: 800px; margin: 0 auto; padding: 20px; }');
    buf.writeln(
        '.metric { display: inline-block; padding: 16px; margin: 8px; border-radius: 8px; background: #f5f5f5; min-width: 120px; text-align: center; }');
    buf.writeln('.metric .value { font-size: 2em; font-weight: bold; }');
    buf.writeln('.metric .label { font-size: 0.9em; color: #666; }');
    buf.writeln(
        '.warning { padding: 12px; margin: 8px 0; border-left: 4px solid #ff9800; background: #fff3e0; border-radius: 4px; }');
    buf.writeln(
        '.warning.high { border-left-color: #f44336; background: #ffebee; }');
    buf.writeln(
        '.score { font-size: 1.5em; padding: 16px; border-radius: 8px; background: #e8f5e9; text-align: center; margin: 16px 0; }');
    buf.writeln('</style></head><body>');
    buf.writeln('<h1>🚀 Performance Report</h1>');
    buf.writeln('<div class="score">Score: $score</div>');
    buf.writeln('<h2>Metrics</h2><div>');

    if (summary['fps'] != null) {
      buf.writeln(
          '<div class="metric"><div class="value">${summary['fps']}</div><div class="label">FPS</div></div>');
    }
    if (summary['fcp_ms'] != null) {
      buf.writeln(
          '<div class="metric"><div class="value">${summary['fcp_ms']}ms</div><div class="label">FCP</div></div>');
    }
    if (summary['lcp_ms'] != null) {
      buf.writeln(
          '<div class="metric"><div class="value">${summary['lcp_ms']}ms</div><div class="label">LCP</div></div>');
    }
    if (summary['cls'] != null) {
      buf.writeln(
          '<div class="metric"><div class="value">${summary['cls']}</div><div class="label">CLS</div></div>');
    }
    if (summary['network_requests'] != null) {
      buf.writeln(
          '<div class="metric"><div class="value">${summary['network_requests']}</div><div class="label">Network Requests</div></div>');
    }

    buf.writeln('</div>');

    if (warnings.isNotEmpty) {
      buf.writeln('<h2>⚠️ Warnings</h2>');
      for (final w in warnings) {
        final severity = w['severity'] ?? 'medium';
        buf.writeln('<div class="warning $severity">');
        buf.writeln(
            '<strong>${w['metric']}</strong>: ${w['value']} (threshold: ${w['threshold']})');
        buf.writeln('<br>${w['recommendation']}');
        buf.writeln('</div>');
      }
    }

    buf.writeln(
        '<p style="color:#999;font-size:0.8em;">Generated: ${report['generated_at']}</p>');
    buf.writeln('</body></html>');
    return buf.toString();
  }
}
