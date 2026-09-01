part of '../server.dart';

extension _SecurityHandlers on FlutterMcpServer {
  /// Handle security scanning tools.
  /// Returns null if the tool is not handled by this group.
  Future<dynamic> _handleSecurityTools(
      String name, Map<String, dynamic> args) async {
    switch (name) {
      case 'security_scan':
        return _handleSecurityScan(args);
      case 'security_xss_scan':
        return _handleSecurityXssScan(args);
      case 'security_check_headers':
        return _handleSecurityCheckHeaders(args);
      case 'security_sensitive_data':
        return _handleSecuritySensitiveData(args);
      case 'generate_test_plan':
        return _handleGenerateTestPlan(args);
      default:
        return null;
    }
  }

  Future<Map<String, dynamic>> _handleSecurityScan(
      Map<String, dynamic> args) async {
    if (_cdpDriver == null) {
      return {'error': 'No CDP connection. Connect to a web app first.'};
    }

    final checks = (args['checks'] as List?)?.cast<String>() ??
        ['xss', 'csrf', 'headers', 'sensitive_data', 'mixed_content'];

    final currentUrl = (await _cdpDriver!
            .evaluate('window.location.href'))['result']?['value'] as String? ??
        'unknown';

    final scanner = SecurityScanner(
      startUrl: currentUrl,
      maxDepth: 0,
      cdpPort: 9222,
      headless: true,
      reportPath: 'security-report.html',
    );

    final findings = await scanner.runChecks(cdp: _cdpDriver!, checks: checks);

    return {
      'status': 'complete',
      'url': currentUrl,
      'total_findings': findings.length,
      'findings': findings.map((f) => f.toJson()).toList(),
      'summary': {
        'critical': findings.where((f) => f.severity == 'Critical').length,
        'high': findings.where((f) => f.severity == 'High').length,
        'medium': findings.where((f) => f.severity == 'Medium').length,
        'low': findings.where((f) => f.severity == 'Low').length,
        'info': findings.where((f) => f.severity == 'Info').length,
      },
    };
  }

  Future<Map<String, dynamic>> _handleSecurityXssScan(
      Map<String, dynamic> args) async {
    if (_cdpDriver == null) {
      return {'error': 'No CDP connection. Connect to a web app first.'};
    }

    final customPayloads = (args['payloads'] as List?)?.cast<String>();

    final currentUrl = (await _cdpDriver!
            .evaluate('window.location.href'))['result']?['value'] as String? ??
        'unknown';

    final scanner = SecurityScanner(
      startUrl: currentUrl,
      maxDepth: 0,
      cdpPort: 9222,
      headless: true,
      reportPath: 'security-report.html',
    );

    final findings = await scanner.runChecks(
      cdp: _cdpDriver!,
      checks: ['xss'],
      customXssPayloads: customPayloads,
    );

    return {
      'status': 'complete',
      'url': currentUrl,
      'xss_findings': findings.map((f) => f.toJson()).toList(),
      'total': findings.length,
    };
  }

  Future<Map<String, dynamic>> _handleSecurityCheckHeaders(
      Map<String, dynamic> args) async {
    if (_cdpDriver == null) {
      return {'error': 'No CDP connection. Connect to a web app first.'};
    }

    final currentUrl = (await _cdpDriver!
            .evaluate('window.location.href'))['result']?['value'] as String? ??
        'unknown';

    final scanner = SecurityScanner(
      startUrl: currentUrl,
      maxDepth: 0,
      cdpPort: 9222,
      headless: true,
      reportPath: 'security-report.html',
    );

    final findings = await scanner.runChecks(
      cdp: _cdpDriver!,
      checks: ['headers'],
    );

    return {
      'status': 'complete',
      'url': currentUrl,
      'header_findings': findings.map((f) => f.toJson()).toList(),
      'total': findings.length,
    };
  }

  Future<Map<String, dynamic>> _handleSecuritySensitiveData(
      Map<String, dynamic> args) async {
    if (_cdpDriver == null) {
      return {'error': 'No CDP connection. Connect to a web app first.'};
    }

    final currentUrl = (await _cdpDriver!
            .evaluate('window.location.href'))['result']?['value'] as String? ??
        'unknown';

    final scanner = SecurityScanner(
      startUrl: currentUrl,
      maxDepth: 0,
      cdpPort: 9222,
      headless: true,
      reportPath: 'security-report.html',
    );

    final findings = await scanner.runChecks(
      cdp: _cdpDriver!,
      checks: ['sensitive_data'],
    );

    return {
      'status': 'complete',
      'url': currentUrl,
      'sensitive_data_findings': findings.map((f) => f.toJson()).toList(),
      'total': findings.length,
    };
  }

  Future<Map<String, dynamic>> _handleGenerateTestPlan(
      Map<String, dynamic> args) async {
    if (_cdpDriver == null) {
      return {'error': 'No CDP connection. Connect to a web app first.'};
    }

    final format = args['format'] as String? ?? 'yaml';
    final includeSecurity = args['include_security'] as bool? ?? true;
    final includeA11y = args['include_a11y'] as bool? ?? true;

    final currentUrl = (await _cdpDriver!
            .evaluate('window.location.href'))['result']?['value'] as String? ??
        'unknown';

    // Use a single-page plan generator that works with existing CDP connection
    final generator = _McpPlanGenerator(
      cdp: _cdpDriver!,
      url: currentUrl,
      includeSecurity: includeSecurity,
      includeA11y: includeA11y,
    );

    final plan = await generator.generate();

    if (format == 'json') {
      return plan;
    } else {
      // Return as YAML string in the result
      return {
        'format': 'yaml',
        'test_plan': plan['test_plan'],
      };
    }
  }
}

/// Lightweight plan generator that works with an existing CDP connection (for MCP tool)
class _McpPlanGenerator {
  final CdpDriver cdp;
  final String url;
  final bool includeSecurity;
  final bool includeA11y;

  _McpPlanGenerator({
    required this.cdp,
    required this.url,
    required this.includeSecurity,
    required this.includeA11y,
  });

  static const _xssPayloads = [
    '<script>alert(1)</script>',
    '"><img src=x onerror=alert(1)>',
  ];

  static const _validInputsByType = {
    'email': 'test@example.com',
    'password': 'Password123!',
    'text': 'Test input',
    'number': '42',
    'tel': '+1234567890',
    'url': 'https://example.com',
    'search': 'search query',
  };

  Future<Map<String, dynamic>> generate() async {
    final tests = <Map<String, dynamic>>[];
    int totalPositive = 0, totalNegative = 0, totalSecurity = 0, totalA11y = 0;

    final pagePath = Uri.parse(url).path;

    // Get interactive elements
    final structured = await cdp.getInteractiveElementsStructured();
    final elements = (structured['elements'] as List<dynamic>?) ?? [];

    final formFields = <Map<String, dynamic>>[];
    final buttons = <Map<String, dynamic>>[];

    for (final el in elements) {
      if (el is! Map<String, dynamic>) continue;
      final type = el['type'] as String? ?? '';
      final actions = (el['actions'] as List?)?.cast<String>() ?? [];
      final text = el['text'] as String? ?? '';
      final ref = el['ref'] as String? ?? '';
      final attrs = el['attributes'] as Map<String, dynamic>? ?? {};
      final inputType = attrs['type'] as String? ?? 'text';
      final name = attrs['name'] as String? ?? '';
      final placeholder = attrs['placeholder'] as String? ?? '';

      if (actions.contains('enter_text') &&
          (type == 'input' || type == 'textarea')) {
        formFields.add({
          'type': inputType,
          'name': name,
          'placeholder': placeholder,
          'ref': ref,
        });
      } else if (actions.contains('tap') &&
          (type == 'button' || type == 'a' || ref.startsWith('button:'))) {
        buttons.add({'text': text, 'ref': ref});
      }
    }

    // Generate form tests
    if (formFields.isNotEmpty) {
      final positiveSteps = <Map<String, dynamic>>[];
      for (final field in formFields) {
        final validValue =
            _validInputsByType[field['type']] ?? 'Test input value';
        final key = (field['name'] as String).isNotEmpty
            ? field['name']
            : (field['placeholder'] as String).isNotEmpty
                ? field['placeholder']
                : field['ref'];
        positiveSteps.add({
          'tool': 'smart_enter_text',
          'args': {'key': key, 'value': validValue}
        });
      }

      final submitBtn = buttons.where((b) {
        final t = (b['text'] as String).toLowerCase();
        return t.contains('submit') ||
            t.contains('sign') ||
            t.contains('login') ||
            t.contains('send') ||
            t.contains('save');
      }).firstOrNull;

      if (submitBtn != null) {
        positiveSteps.add({
          'tool': 'smart_tap',
          'args': {'text': submitBtn['text']}
        });
      }
      positiveSteps.add({
        'tool': 'smart_assert',
        'args': {'type': 'no_error'}
      });

      tests.add({
        'name': 'Submit form with valid data',
        'type': 'positive',
        'steps': positiveSteps,
      });
      totalPositive++;

      for (final field in formFields) {
        final key = (field['name'] as String).isNotEmpty
            ? field['name']
            : (field['placeholder'] as String).isNotEmpty
                ? field['placeholder']
                : field['ref'];

        tests.add({
          'name': 'Empty input for "$key"',
          'type': 'negative',
          'steps': [
            {
              'tool': 'smart_enter_text',
              'args': {'key': key, 'value': ''}
            },
            {
              'tool': 'smart_assert',
              'args': {'type': 'visible', 'text': 'required'}
            },
          ],
        });
        totalNegative++;

        tests.add({
          'name': 'Special characters in "$key"',
          'type': 'negative',
          'steps': [
            {
              'tool': 'smart_enter_text',
              'args': {'key': key, 'value': '!@#\$%^&*()_+-=[]{}|;:\'",.<>?/'}
            },
            {
              'tool': 'smart_assert',
              'args': {'type': 'no_error'}
            },
          ],
        });
        totalNegative++;

        if (includeSecurity) {
          for (final payload in _xssPayloads) {
            tests.add({
              'name': 'XSS in "$key"',
              'type': 'security',
              'steps': [
                {
                  'tool': 'smart_enter_text',
                  'args': {'key': key, 'value': payload}
                },
                {
                  'tool': 'smart_assert',
                  'args': {'type': 'no_alert'}
                },
              ],
            });
            totalSecurity++;
          }
        }
      }
    }

    for (final btn in buttons) {
      tests.add({
        'name': 'Click "${btn['text']}" button',
        'type': 'positive',
        'steps': [
          {
            'tool': 'smart_tap',
            'args': {'text': btn['text']}
          },
          {
            'tool': 'smart_assert',
            'args': {'type': 'no_error'}
          },
        ],
      });
      totalPositive++;
    }

    if (includeA11y) {
      final a11yResult = await cdp.evaluate('''
        JSON.stringify({
          imagesWithoutAlt: document.querySelectorAll('img:not([alt])').length,
          inputsWithoutLabel: document.querySelectorAll('input:not([aria-label]):not([id])').length
        })
      ''');
      final a11yJson = a11yResult['result']?['value'] as String?;
      if (a11yJson != null) {
        final a11y = jsonDecode(a11yJson) as Map<String, dynamic>;
        if ((a11y['imagesWithoutAlt'] as int? ?? 0) > 0) {
          tests.add({
            'name': 'A11y: Images missing alt text',
            'type': 'a11y',
            'steps': [
              {
                'tool': 'accessibility_audit',
                'args': {'check': 'images_without_alt'}
              },
            ],
          });
          totalA11y++;
        }
        if ((a11y['inputsWithoutLabel'] as int? ?? 0) > 0) {
          tests.add({
            'name': 'A11y: Inputs missing labels',
            'type': 'a11y',
            'steps': [
              {
                'tool': 'accessibility_audit',
                'args': {'check': 'inputs_without_label'}
              },
            ],
          });
          totalA11y++;
        }
      }
    }

    final totalTests =
        totalPositive + totalNegative + totalSecurity + totalA11y;

    return {
      'test_plan': {
        'app_url': url,
        'generated_at': DateTime.now().toUtc().toIso8601String(),
        'pages': [
          {
            'url': pagePath.isEmpty ? '/' : pagePath,
            'tests': tests,
          }
        ],
        'summary': {
          'total_tests': totalTests,
          'by_type': {
            'positive': totalPositive,
            'negative': totalNegative,
            'security': totalSecurity,
            'a11y': totalA11y,
          },
          'estimated_duration': '${(totalTests * 4 / 60).ceil()} min',
        },
      },
    };
  }
}
