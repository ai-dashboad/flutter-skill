part of '../server.dart';

extension _BugReportHandlers on FlutterMcpServer {
  Future<dynamic> _handleBugReportTools(
      String name, Map<String, dynamic> args) async {
    switch (name) {
      case 'create_bug_report':
        return await _createBugReport(args);
      case 'create_github_issue':
        return await _createGithubIssue(args);
      default:
        return null;
    }
  }

  /// Generate a structured bug report from current state.
  Future<Map<String, dynamic>> _createBugReport(
      Map<String, dynamic> args) async {
    final title = args['title'] as String? ?? 'Bug Report';
    final steps = (args['steps'] as List?)?.cast<String>();
    final severity = args['severity'] as String? ?? 'medium';
    final format = args['format'] as String? ?? 'markdown';
    final savePath = args['save_path'] as String?;

    // Collect environment info
    final env = <String, dynamic>{
      'os': Platform.operatingSystem,
      'os_version': Platform.operatingSystemVersion,
      'dart_version': Platform.version,
      'timestamp': DateTime.now().toIso8601String(),
    };

    // Collect info from CDP if connected
    String? screenshotPath;
    String? currentUrl;
    String? pageTitle;
    List<String>? consoleErrors;
    Map<String, dynamic>? viewport;

    final cdp = _cdpDriver;
    if (cdp != null && cdp.isConnected) {
      // Screenshot
      try {
        final screenshot = await cdp.takeScreenshot(quality: 0.8);
        if (screenshot != null) {
          final tmpDir = Directory.systemTemp;
          final file = File(
              '${tmpDir.path}/bug_report_${DateTime.now().millisecondsSinceEpoch}.png');
          await file.writeAsBytes(base64.decode(screenshot));
          screenshotPath = file.path;
        }
      } catch (_) {}

      // URL & title
      try {
        final urlResult = await cdp.eval('window.location.href');
        currentUrl = urlResult['result']?['value'] as String?;
        final titleResult = await cdp.eval('document.title');
        pageTitle = titleResult['result']?['value'] as String?;
      } catch (_) {}

      // Viewport
      try {
        final vpResult = await cdp.eval(
            'JSON.stringify({width: window.innerWidth, height: window.innerHeight, dpr: window.devicePixelRatio})');
        final vpJson = vpResult['result']?['value'] as String?;
        if (vpJson != null)
          viewport = Map<String, dynamic>.from(jsonDecode(vpJson));
      } catch (_) {}

      // Browser version
      try {
        final uaResult = await cdp.eval('navigator.userAgent');
        final ua = uaResult['result']?['value'] as String?;
        if (ua != null) env['user_agent'] = ua;
      } catch (_) {}

      // Console errors
      try {
        final messages = await cdp.getConsoleMessages();
        consoleErrors = <String>[];
        if (messages['messages'] is List) {
          for (final m in messages['messages'] as List) {
            if (m is Map &&
                (m['level'] == 'error' || m['level'] == 'warning')) {
              consoleErrors.add('${m['level']}: ${m['text']}');
            }
          }
        }
      } catch (_) {}
    }

    // Auto-extract repro steps from recording if available
    List<String> reproSteps;
    if (steps != null && steps.isNotEmpty) {
      reproSteps = steps;
    } else if (_recordedSteps.isNotEmpty) {
      reproSteps = _recordedSteps.map((s) {
        final tool = s['tool'] as String? ?? 'unknown';
        final params = s['params'] as Map? ?? {};
        switch (tool) {
          case 'tap':
            return 'Tap on "${params['text'] ?? params['key'] ?? 'element'}"';
          case 'enter_text':
            return 'Enter "${params['text']}" into ${params['key'] ?? 'field'}';
          case 'scroll':
          case 'swipe':
            return 'Swipe ${params['direction'] ?? 'down'}';
          case 'navigate':
            return 'Navigate to ${params['url']}';
          case 'go_back':
            return 'Go back';
          default:
            return '$tool(${params.entries.map((e) => '${e.key}: ${e.value}').join(', ')})';
        }
      }).toList();
    } else {
      reproSteps = ['1. [Describe steps to reproduce]'];
    }

    // Format the report
    String body;
    switch (format) {
      case 'github_issue':
        body = _formatGithubIssue(
          title: title,
          severity: severity,
          steps: reproSteps,
          env: env,
          currentUrl: currentUrl,
          pageTitle: pageTitle,
          viewport: viewport,
          consoleErrors: consoleErrors,
          screenshotPath: screenshotPath,
        );
        break;
      case 'jira':
        body = _formatJira(
          title: title,
          severity: severity,
          steps: reproSteps,
          env: env,
          currentUrl: currentUrl,
          pageTitle: pageTitle,
          viewport: viewport,
          consoleErrors: consoleErrors,
          screenshotPath: screenshotPath,
        );
        break;
      default:
        body = _formatMarkdown(
          title: title,
          severity: severity,
          steps: reproSteps,
          env: env,
          currentUrl: currentUrl,
          pageTitle: pageTitle,
          viewport: viewport,
          consoleErrors: consoleErrors,
          screenshotPath: screenshotPath,
        );
    }

    // Save to file if requested
    if (savePath != null) {
      final file = File(savePath);
      await file.parent.create(recursive: true);
      await file.writeAsString(body);
    }

    return {
      'success': true,
      'title': title,
      'severity': severity,
      'format': format,
      'body': body,
      if (screenshotPath != null) 'screenshot_path': screenshotPath,
      if (savePath != null) 'saved_to': savePath,
      'environment': env,
      'repro_steps_count': reproSteps.length,
      if (consoleErrors != null && consoleErrors.isNotEmpty)
        'console_errors_count': consoleErrors.length,
    };
  }

  /// Create a GitHub issue with bug report.
  Future<Map<String, dynamic>> _createGithubIssue(
      Map<String, dynamic> args) async {
    final repo = args['repo'] as String?;
    final title = args['title'] as String?;
    if (repo == null || title == null) {
      return {
        'success': false,
        'error': 'repo and title are required',
      };
    }

    final severity = args['severity'] as String? ?? 'medium';
    final steps = (args['steps'] as List?)?.cast<String>();
    final labels = (args['labels'] as List?)?.cast<String>() ?? ['bug'];

    // Generate the bug report body
    final reportResult = await _createBugReport({
      'title': title,
      'severity': severity,
      if (steps != null) 'steps': steps,
      'format': 'github_issue',
    });

    final body = reportResult['body'] as String? ?? '';

    // Create issue via gh CLI
    try {
      final labelArgs = labels.map((l) => '--label=$l').toList();

      final result = await Process.run('gh', [
        'issue',
        'create',
        '--repo',
        repo,
        '--title',
        title,
        '--body',
        body,
        ...labelArgs,
      ]);

      if (result.exitCode == 0) {
        final issueUrl = result.stdout.toString().trim();
        return {
          'success': true,
          'issue_url': issueUrl,
          'repo': repo,
          'title': title,
          'labels': labels,
        };
      } else {
        return {
          'success': false,
          'error': 'gh CLI failed: ${result.stderr}',
          'hint':
              'Make sure gh CLI is installed and authenticated (gh auth login)',
        };
      }
    } catch (e) {
      return {
        'success': false,
        'error': 'Failed to run gh CLI: $e',
        'hint':
            'Install gh CLI: https://cli.github.com/ and run "gh auth login"',
      };
    }
  }

  // --- Formatters ---

  String _formatMarkdown({
    required String title,
    required String severity,
    required List<String> steps,
    required Map<String, dynamic> env,
    String? currentUrl,
    String? pageTitle,
    Map<String, dynamic>? viewport,
    List<String>? consoleErrors,
    String? screenshotPath,
  }) {
    final buf = StringBuffer();
    buf.writeln('# $title');
    buf.writeln();
    buf.writeln('**Severity:** $severity');
    buf.writeln('**Date:** ${env['timestamp']}');
    if (currentUrl != null) buf.writeln('**URL:** $currentUrl');
    if (pageTitle != null) buf.writeln('**Page:** $pageTitle');
    buf.writeln();

    buf.writeln('## Steps to Reproduce');
    for (var i = 0; i < steps.length; i++) {
      buf.writeln('${i + 1}. ${steps[i]}');
    }
    buf.writeln();

    buf.writeln('## Environment');
    buf.writeln('- OS: ${env['os']} ${env['os_version']}');
    if (env['user_agent'] != null) {
      buf.writeln('- Browser: ${env['user_agent']}');
    }
    if (viewport != null) {
      buf.writeln(
          '- Viewport: ${viewport['width']}x${viewport['height']} (${viewport['dpr']}x)');
    }
    buf.writeln();

    if (consoleErrors != null && consoleErrors.isNotEmpty) {
      buf.writeln('## Console Errors');
      buf.writeln('```');
      for (final error in consoleErrors.take(20)) {
        buf.writeln(error);
      }
      buf.writeln('```');
      buf.writeln();
    }

    if (screenshotPath != null) {
      buf.writeln('## Screenshot');
      buf.writeln('Saved to: `$screenshotPath`');
    }

    return buf.toString();
  }

  String _formatGithubIssue({
    required String title,
    required String severity,
    required List<String> steps,
    required Map<String, dynamic> env,
    String? currentUrl,
    String? pageTitle,
    Map<String, dynamic>? viewport,
    List<String>? consoleErrors,
    String? screenshotPath,
  }) {
    final buf = StringBuffer();
    buf.writeln('## Bug Report');
    buf.writeln();
    buf.writeln('**Severity:** $severity');
    if (currentUrl != null) buf.writeln('**URL:** $currentUrl');
    if (pageTitle != null) buf.writeln('**Page:** $pageTitle');
    buf.writeln();

    buf.writeln('### Steps to Reproduce');
    for (var i = 0; i < steps.length; i++) {
      buf.writeln('${i + 1}. ${steps[i]}');
    }
    buf.writeln();

    buf.writeln('### Expected Behavior');
    buf.writeln('<!-- Describe what should happen -->');
    buf.writeln();

    buf.writeln('### Actual Behavior');
    buf.writeln('<!-- Describe what actually happens -->');
    buf.writeln();

    buf.writeln('### Environment');
    buf.writeln('| Key | Value |');
    buf.writeln('|-----|-------|');
    buf.writeln('| OS | ${env['os']} ${env['os_version']} |');
    if (env['user_agent'] != null) {
      buf.writeln('| Browser | ${env['user_agent']} |');
    }
    if (viewport != null) {
      buf.writeln(
          '| Viewport | ${viewport['width']}x${viewport['height']} (${viewport['dpr']}x) |');
    }
    buf.writeln();

    if (consoleErrors != null && consoleErrors.isNotEmpty) {
      buf.writeln('### Console Errors');
      buf.writeln(
          '<details><summary>Show errors (${consoleErrors.length})</summary>');
      buf.writeln();
      buf.writeln('```');
      for (final error in consoleErrors.take(20)) {
        buf.writeln(error);
      }
      buf.writeln('```');
      buf.writeln('</details>');
      buf.writeln();
    }

    if (screenshotPath != null) {
      buf.writeln('### Screenshot');
      buf.writeln('<!-- Attach: $screenshotPath -->');
    }

    return buf.toString();
  }

  String _formatJira({
    required String title,
    required String severity,
    required List<String> steps,
    required Map<String, dynamic> env,
    String? currentUrl,
    String? pageTitle,
    Map<String, dynamic>? viewport,
    List<String>? consoleErrors,
    String? screenshotPath,
  }) {
    final buf = StringBuffer();
    buf.writeln('h2. $title');
    buf.writeln();
    buf.writeln('*Severity:* $severity');
    if (currentUrl != null) buf.writeln('*URL:* $currentUrl');
    if (pageTitle != null) buf.writeln('*Page:* $pageTitle');
    buf.writeln();

    buf.writeln('h3. Steps to Reproduce');
    for (var i = 0; i < steps.length; i++) {
      buf.writeln('# ${steps[i]}');
    }
    buf.writeln();

    buf.writeln('h3. Expected Result');
    buf.writeln('_Describe expected behavior_');
    buf.writeln();

    buf.writeln('h3. Actual Result');
    buf.writeln('_Describe actual behavior_');
    buf.writeln();

    buf.writeln('h3. Environment');
    buf.writeln('||Key||Value||');
    buf.writeln('|OS|${env['os']} ${env['os_version']}|');
    if (env['user_agent'] != null) {
      buf.writeln('|Browser|${env['user_agent']}|');
    }
    if (viewport != null) {
      buf.writeln(
          '|Viewport|${viewport['width']}x${viewport['height']} (${viewport['dpr']}x)|');
    }
    buf.writeln();

    if (consoleErrors != null && consoleErrors.isNotEmpty) {
      buf.writeln('h3. Console Errors');
      buf.writeln('{code}');
      for (final error in consoleErrors.take(20)) {
        buf.writeln(error);
      }
      buf.writeln('{code}');
    }

    return buf.toString();
  }
}
