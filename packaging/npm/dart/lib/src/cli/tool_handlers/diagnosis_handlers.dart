part of '../server.dart';

extension _DiagnosisHandlers on FlutterMcpServer {
  // ==================== Smart Diagnosis ====================

  /// Diagnose patterns for log analysis
  static const List<Map<String, dynamic>> _diagnosisPatterns = [
    // Network errors
    {
      'pattern': r'DioException.*connection',
      'type': 'network_connection_error',
      'severity': 'critical',
      'message': 'API connection failed',
      'suggestion': {
        'action': 'Check network and API configuration',
        'steps': [
          '1. Verify device network connection',
          '2. Check if API endpoint is accessible',
          '3. If using local mock, ensure server is running',
        ],
      },
      'next_step': {
        'tool': 'tap',
        'params': {'text': 'Retry'},
        'description': 'Tap retry button'
      },
    },
    {
      'pattern': r'SocketException',
      'type': 'network_connection_error',
      'severity': 'critical',
      'message': 'Socket connection failed',
      'suggestion': {
        'action': 'Check network connectivity',
        'steps': [
          '1. Verify network connection',
          '2. Check firewall settings',
          '3. Verify server is running',
        ],
      },
      'next_step': {
        'tool': 'hot_restart',
        'params': {},
        'description': 'Restart app to retry connection'
      },
    },
    {
      'pattern': r'TimeoutException',
      'type': 'network_timeout',
      'severity': 'critical',
      'message': 'Request timeout',
      'suggestion': {
        'action': 'Handle slow network or server',
        'steps': [
          '1. Check server response time',
          '2. Consider increasing timeout',
          '3. Check for network congestion',
        ],
      },
      'next_step': {
        'tool': 'tap',
        'params': {'text': 'Retry'},
        'description': 'Retry the operation'
      },
    },
    // Layout errors
    {
      'pattern': r'RenderFlex overflowed',
      'type': 'layout_overflow',
      'severity': 'warning',
      'message': 'Layout overflow detected',
      'suggestion': {
        'action': 'Fix layout overflow',
        'steps': [
          '1. Use Expanded or Flexible to wrap child widgets',
          '2. Add SingleChildScrollView for scrollable content',
          '3. Check fixed sizes and constraints',
        ],
        'code_example': '''// Before: Row(children: [Text('Long text...')])
// After: Row(children: [Expanded(child: Text('Long text...', overflow: TextOverflow.ellipsis))])''',
      },
      'next_step': {
        'tool': 'hot_reload',
        'params': {},
        'description': 'Hot reload after fixing code'
      },
    },
    // Null errors
    {
      'pattern': r'Null check operator',
      'type': 'null_check_error',
      'severity': 'critical',
      'message': 'Null check failed',
      'suggestion': {
        'action': 'Handle null value properly',
        'steps': [
          '1. Check data loading state before accessing',
          '2. Use null-aware operators (?., ??)',
          '3. Add proper null checks',
        ],
      },
      'next_step': {
        'tool': 'hot_restart',
        'params': {},
        'description': 'Restart after fixing null issue'
      },
    },
    // State errors
    {
      'pattern': r'setState.*disposed',
      'type': 'state_error',
      'severity': 'warning',
      'message': 'setState called on disposed widget',
      'suggestion': {
        'action': 'Check mounted state before setState',
        'steps': [
          '1. Add if (mounted) before setState',
          '2. Cancel async operations in dispose()',
          '3. Use proper lifecycle management',
        ],
        'code_example': '''// Add mounted check
if (mounted) {
  setState(() { ... });
}''',
      },
      'next_step': {
        'tool': 'hot_reload',
        'params': {},
        'description': 'Hot reload after fixing'
      },
    },
    // Memory warnings
    {
      'pattern': r'memory.*warning|OutOfMemory',
      'type': 'memory_high',
      'severity': 'warning',
      'message': 'High memory usage detected',
      'suggestion': {
        'action': 'Optimize memory usage',
        'steps': [
          '1. Check for large images not being disposed',
          '2. Use ListView.builder instead of ListView',
          '3. Cancel streams and timers in dispose()',
        ],
      },
      'next_step': {
        'tool': 'hot_restart',
        'params': {},
        'description': 'Restart to free memory'
      },
    },
  ];

  /// Perform comprehensive diagnosis
  Future<Map<String, dynamic>> _performDiagnosis(
      Map<String, dynamic> args, FlutterSkillClient client) async {
    final scope = args['scope'] ?? 'all';
    // ignore: unused_local_variable
    final logLines = args['log_lines'] ?? 100; // Reserved for future use
    final includeScreenshot = args['include_screenshot'] ?? false;

    final issues = <Map<String, dynamic>>[];
    final suggestions = <Map<String, dynamic>>[];
    final nextSteps = <Map<String, dynamic>>[];
    var issueCounter = 1;

    // Analyze logs if scope includes logs
    if (scope == 'all' || scope == 'logs') {
      try {
        final logs = await client.getLogs();
        final logsStr = logs.toString();

        // Check each pattern
        for (final pattern in _diagnosisPatterns) {
          final regex =
              RegExp(pattern['pattern'] as String, caseSensitive: false);
          if (regex.hasMatch(logsStr)) {
            final issueId = 'E${issueCounter.toString().padLeft(3, '0')}';
            issueCounter++;

            issues.add({
              'id': issueId,
              'type': pattern['type'],
              'severity': pattern['severity'],
              'message': pattern['message'],
            });

            final suggestion = pattern['suggestion'] as Map<String, dynamic>;
            suggestions.add({
              'for_issue': issueId,
              'priority': pattern['severity'] == 'critical' ? 1 : 2,
              ...suggestion,
            });

            if (pattern['next_step'] != null) {
              nextSteps.add({
                ...pattern['next_step'] as Map<String, dynamic>,
                'for_issue': issueId,
              });
            }
          }
        }
      } catch (e) {
        // Log analysis failed, continue with other diagnostics
      }
    }

    // Analyze UI state if scope includes UI
    if (scope == 'all' || scope == 'ui') {
      try {
        final elements = await client.getInteractiveElements();

        // Check for empty state
        if (elements.isEmpty) {
          final issueId = 'E${issueCounter.toString().padLeft(3, '0')}';
          issueCounter++;

          issues.add({
            'id': issueId,
            'type': 'empty_state',
            'severity': 'warning',
            'message': 'No interactive elements found on screen',
          });

          suggestions.add({
            'for_issue': issueId,
            'priority': 2,
            'action': 'Check page loading state',
            'steps': [
              '1. Verify data loaded successfully',
              '2. Check if showing loading indicator',
              '3. Review error handling logic',
            ],
          });

          nextSteps.add({
            'tool': 'screenshot',
            'params': {},
            'description': 'Take screenshot to inspect current state',
            'for_issue': issueId,
          });
        }
      } catch (e) {
        // UI analysis failed
      }
    }

    // Analyze performance if scope includes performance
    if (scope == 'all' || scope == 'performance') {
      try {
        final memoryStats = await client.getMemoryStats();
        final heapUsed = memoryStats['heapUsed'] as int? ?? 0;
        final heapMB = heapUsed / (1024 * 1024);

        // Check high memory usage (> 300MB)
        if (heapMB > 300) {
          final issueId = 'E${issueCounter.toString().padLeft(3, '0')}';
          issueCounter++;

          issues.add({
            'id': issueId,
            'type': 'memory_high',
            'severity': heapMB > 500 ? 'critical' : 'warning',
            'message':
                'Memory usage ${heapMB.toStringAsFixed(1)}MB exceeds 300MB threshold',
          });

          suggestions.add({
            'for_issue': issueId,
            'priority': heapMB > 500 ? 1 : 2,
            'action': 'Reduce memory usage',
            'steps': [
              '1. Dispose large images when not visible',
              '2. Use ListView.builder for long lists',
              '3. Check for memory leaks in streams/timers',
            ],
          });

          nextSteps.add({
            'tool': 'hot_restart',
            'params': {},
            'description': 'Restart app to release memory',
            'for_issue': issueId,
          });
        }
      } catch (e) {
        // Performance analysis failed
      }
    }

    // Calculate health score
    final criticalCount =
        issues.where((i) => i['severity'] == 'critical').length;
    final warningCount = issues.where((i) => i['severity'] == 'warning').length;
    final healthScore =
        (100 - (criticalCount * 30) - (warningCount * 10)).clamp(0, 100);

    // Build result
    final result = <String, dynamic>{
      'success': true,
      'timestamp': DateTime.now().toIso8601String(),
      'summary': {
        'total_issues': issues.length,
        'critical': criticalCount,
        'warning': warningCount,
        'info': issues.where((i) => i['severity'] == 'info').length,
        'health_score': healthScore,
      },
      'issues': issues,
      'suggestions': suggestions,
      'next_steps': nextSteps,
    };

    // Include screenshot if requested
    if (includeScreenshot) {
      try {
        final screenshot = await client.takeScreenshot();
        result['screenshot'] = screenshot;
      } catch (e) {
        // Screenshot failed
      }
    }

    return result;
  }

  // ==================== End Smart Diagnosis ====================

  // ==================== Build Error Helpers ====================

  /// Get suggestions based on build error message
  List<String> _getBuildErrorSuggestions(String errorMessage) {
    final suggestions = <String>[];
    final lowerError = errorMessage.toLowerCase();

    // SDK not integrated
    if (lowerError.contains('flutterskillbinding') ||
        lowerError.contains('flutter_skill') &&
            lowerError.contains('not found') ||
        lowerError.contains('ext.flutter.flutter_skill') ||
        lowerError.contains('method not found') &&
            lowerError.contains('-32601')) {
      suggestions.addAll([
        '❌ flutter_skill SDK not integrated in the app',
        '',
        '1. Add dependency:',
        '   flutter pub add flutter_skill',
        '',
        '2. Add to lib/main.dart BEFORE runApp():',
        "   import 'package:flutter_skill/flutter_skill.dart';",
        '   void main() {',
        '     FlutterSkillBinding.ensureInitialized();',
        '     runApp(MyApp());',
        '   }',
        '',
        '3. Hot restart (not hot reload):',
        '   hot_restart()',
        '',
        'Auto-fix: run  diagnose_project()  to patch automatically.',
      ]);
      return suggestions;
    }

    // Port already in use
    if (lowerError.contains('address already in use') ||
        lowerError.contains('port') && lowerError.contains('in use') ||
        lowerError.contains('bind failed') ||
        lowerError.contains('osError: address already in use')) {
      suggestions.addAll([
        '❌ Port already in use',
        '',
        '1. Find and kill the process using the port:',
        '   lsof -ti :50000 | xargs kill -9',
        '',
        '2. Or use a different port:',
        '   flutter run --vm-service-port=50001',
        '   connect_app(uri: "ws://127.0.0.1:50001/TOKEN=/ws")',
        '',
        '3. Or let flutter choose a free port:',
        '   launch_app(project_path: ".")  ← auto-selects free port',
      ]);
      return suggestions;
    }

    // Wrong Flutter version
    if (lowerError.contains('requires flutter') ||
        lowerError.contains('flutter sdk') && lowerError.contains('version') ||
        lowerError.contains('unsupported flutter') ||
        lowerError.contains('flutter >=')) {
      suggestions.addAll([
        '❌ Flutter version incompatibility',
        '',
        '1. Check your Flutter version:',
        '   flutter --version',
        '',
        '2. flutter_skill requires Flutter 3.0+',
        '   Upgrade: flutter upgrade',
        '',
        '3. If on a fixed version, use a compatible release:',
        '   flutter_skill: ^0.8.0  (check pub.dev for version matrix)',
      ]);
      return suggestions;
    }

    // Missing platform tools
    if (lowerError.contains('flutter doctor') ||
        lowerError.contains('no connected device') ||
        lowerError.contains('no devices found')) {
      suggestions.addAll([
        '❌ No devices / platform tools not set up',
        '',
        '1. Run flutter doctor:',
        '   flutter doctor -v',
        '',
        '2. iOS Simulator: open Xcode → Simulator',
        '   Or: open -a Simulator',
        '',
        '3. Android: ensure AVD is running or physical device connected',
        '   flutter devices  ← list available devices',
        '',
        '4. Pass device explicitly:',
        '   launch_app(project_path: ".", device_id: "iPhone 16 Pro")',
      ]);
      return suggestions;
    }

    // iOS specific errors
    if (lowerError.contains('xcode') || lowerError.contains('cocoapods')) {
      suggestions.addAll([
        'iOS Build Error Detected',
        '',
        'Common fixes:',
      ]);

      if (lowerError.contains('webrtc') || lowerError.contains('pod')) {
        suggestions.addAll([
          '1. Clean and reinstall CocoaPods:',
          '   cd ios && rm -rf Pods Podfile.lock && pod install',
          '',
          '2. Clean Flutter build cache:',
          '   flutter clean && flutter pub get',
          '',
          '3. If still failing, clear Xcode cache:',
          '   rm -rf ~/Library/Developer/Xcode/DerivedData',
        ]);
      } else if (lowerError.contains('signing') ||
          lowerError.contains('provisioning')) {
        suggestions.addAll([
          '1. Check Xcode signing settings',
          '2. Verify Apple Developer account',
          '3. Update provisioning profiles',
        ]);
      } else {
        suggestions.addAll([
          '1. Try: flutter clean && flutter pub get',
          '2. Try: cd ios && pod install',
          '3. Check Xcode version compatibility',
        ]);
      }
    }

    // Android specific errors
    else if (lowerError.contains('gradle') || lowerError.contains('android')) {
      suggestions.addAll([
        'Android Build Error Detected',
        '',
        '1. Clean and rebuild:',
        '   flutter clean && flutter pub get',
        '',
        '2. Invalidate Gradle cache:',
        '   cd android && ./gradlew clean',
        '',
        '3. Check gradle-wrapper.properties version',
      ]);
    }

    // Dependency errors
    else if (lowerError.contains('dependency') ||
        lowerError.contains('version solving failed')) {
      suggestions.addAll([
        'Dependency Conflict Detected',
        '',
        '1. Run: flutter pub outdated',
        '2. Update dependencies: flutter pub upgrade',
        '3. Check pubspec.yaml for version conflicts',
      ]);
    }

    // General build errors
    else {
      suggestions.addAll([
        'Build Failed',
        '',
        '1. Run: flutter doctor -v',
        '2. Try: flutter clean && flutter pub get',
        '3. Check the error details above for specific issues',
      ]);
    }

    return suggestions;
  }

  /// Get quick fix commands based on error message
  Map<String, String> _getQuickFixes(String errorMessage, String projectPath) {
    final lowerError = errorMessage.toLowerCase();

    // iOS CocoaPods/WebRTC fix
    if (lowerError.contains('webrtc') ||
        (lowerError.contains('cocoapods') && lowerError.contains('pod'))) {
      return {
        'description': 'Clean and reinstall CocoaPods dependencies',
        'command':
            'cd $projectPath/ios && rm -rf Pods Podfile.lock .symlinks && pod deintegrate && pod install && cd ..',
        'platform': 'iOS',
      };
    }

    // General iOS build fix
    if (lowerError.contains('xcode') || lowerError.contains('ios')) {
      return {
        'description': 'Clean iOS build and Flutter cache',
        'command':
            'cd $projectPath && rm -rf ios/Pods ios/Podfile.lock build && flutter clean && flutter pub get',
        'platform': 'iOS',
      };
    }

    // Android build fix
    if (lowerError.contains('gradle') || lowerError.contains('android')) {
      return {
        'description': 'Clean Android build and Gradle cache',
        'command':
            'cd $projectPath && flutter clean && cd android && ./gradlew clean && cd ..',
        'platform': 'Android',
      };
    }

    // General fix
    return {
      'description': 'Clean Flutter build cache',
      'command': 'cd $projectPath && flutter clean && flutter pub get',
      'platform': 'All',
    };
  }
}
