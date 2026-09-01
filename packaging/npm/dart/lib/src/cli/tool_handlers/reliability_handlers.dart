part of '../server.dart';

extension _ReliabilityHandlers on FlutterMcpServer {
  /// Handle reliability/flaky test detection tools.
  /// Returns null if the tool is not handled by this group.
  Future<dynamic> _handleReliabilityTools(
      String name, Map<String, dynamic> args) async {
    if (name == 'retry_on_fail') {
      return _handleRetryOnFail(args);
    }
    if (name == 'stability_check') {
      return _handleStabilityCheck(args);
    }
    return null;
  }

  Future<Map<String, dynamic>> _handleRetryOnFail(
      Map<String, dynamic> args) async {
    final action = args['action'] as String?;
    final arguments = (args['arguments'] as Map<String, dynamic>?) ?? {};
    final maxRetries = args['max_retries'] as int? ?? 3;
    final delayMs = args['delay_ms'] as int? ?? 1000;

    if (action == null) {
      return {
        'success': false,
        'error': 'action parameter is required. Specify the tool name to retry.'
      };
    }

    dynamic lastError;
    for (int attempt = 1; attempt <= maxRetries + 1; attempt++) {
      try {
        final result = await _executeToolInner(action, Map.from(arguments));

        // Check if result indicates failure
        if (result is Map && result['success'] == false) {
          lastError = result['error'] ?? 'Tool returned success: false';
          if (attempt <= maxRetries) {
            stderr.writeln(
                '[retry_on_fail] $action attempt $attempt failed: $lastError');
            await Future.delayed(Duration(milliseconds: delayMs));
            continue;
          }
          return {
            'success': false,
            'flaky': false,
            'action': action,
            'attempts': attempt,
            'last_error': lastError.toString(),
          };
        }

        // Success
        if (attempt > 1) {
          // Passed on retry = flaky
          return {
            'success': true,
            'flaky': true,
            'action': action,
            'attempts': attempt,
            'message':
                'Test passed on attempt $attempt of ${maxRetries + 1} — marked as FLAKY',
            'result': result,
          };
        }

        return {
          'success': true,
          'flaky': false,
          'action': action,
          'attempts': 1,
          'result': result,
        };
      } catch (e) {
        lastError = e;
        if (attempt <= maxRetries) {
          stderr.writeln('[retry_on_fail] $action attempt $attempt threw: $e');
          await Future.delayed(Duration(milliseconds: delayMs));
          continue;
        }
      }
    }

    return {
      'success': false,
      'flaky': false,
      'action': action,
      'attempts': maxRetries + 1,
      'last_error': lastError.toString(),
    };
  }

  Future<Map<String, dynamic>> _handleStabilityCheck(
      Map<String, dynamic> args) async {
    final action = args['action'] as String?;
    final arguments = (args['arguments'] as Map<String, dynamic>?) ?? {};
    final runs = args['runs'] as int? ?? 5;

    if (action == null) {
      return {'success': false, 'error': 'action is required'};
    }

    int passed = 0;
    int failed = 0;
    final results = <Map<String, dynamic>>[];

    for (int i = 1; i <= runs; i++) {
      final sw = Stopwatch()..start();
      try {
        final result = await _executeToolInner(action, Map.from(arguments));
        sw.stop();

        final success = result is! Map || result['success'] != false;

        if (success) {
          passed++;
        } else {
          failed++;
        }

        results.add({
          'run': i,
          'success': success,
          'time_ms': sw.elapsedMilliseconds,
          if (!success) 'error': result['error'],
        });
      } catch (e) {
        sw.stop();
        failed++;
        results.add({
          'run': i,
          'success': false,
          'time_ms': sw.elapsedMilliseconds,
          'error': e.toString(),
        });
      }
    }

    final successRate = runs > 0 ? (passed / runs * 100).round() : 0;
    final isFlaky = passed > 0 && failed > 0;

    return {
      'success': failed == 0,
      'action': action,
      'total_runs': runs,
      'passed': passed,
      'failed': failed,
      'success_rate': successRate,
      'flaky': isFlaky,
      'verdict': isFlaky
          ? 'FLAKY — passes ${successRate}% of the time'
          : failed == 0
              ? 'STABLE — passed all $runs runs'
              : 'FAILING — failed all $runs runs',
      'runs': results,
    };
  }
}
