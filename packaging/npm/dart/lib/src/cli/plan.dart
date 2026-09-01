import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../bridge/cdp_driver.dart';

/// `flutter-skill plan` — AI Test Plan Generator.
///
/// Usage:
///   flutter-skill plan https://my-app.com [--output=test-plan.yaml] [--format=yaml|json] [--depth=3]
Future<void> runPlan(List<String> args) async {
  String? url;
  int depth = 3;
  String? outputPath;
  String format = 'yaml';
  int cdpPort = 0; // 0 = auto-assign random port
  bool headless = true;
  bool includeSecurity = true;
  bool includeA11y = true;
  int maxPages = 10;
  int maxLinks = 20;

  for (final arg in args) {
    if (arg.startsWith('--depth=')) {
      depth = int.parse(arg.substring(8));
    } else if (arg.startsWith('--output=')) {
      outputPath = arg.substring(9);
    } else if (arg.startsWith('--format=')) {
      format = arg.substring(9);
    } else if (arg.startsWith('--cdp-port=')) {
      cdpPort = int.parse(arg.substring(11));
    } else if (arg == '--no-headless') {
      headless = false;
    } else if (arg == '--no-security') {
      includeSecurity = false;
    } else if (arg == '--no-a11y') {
      includeA11y = false;
    } else if (arg.startsWith('--max-pages=')) {
      maxPages = int.parse(arg.substring(12));
    } else if (arg.startsWith('--max-links=')) {
      maxLinks = int.parse(arg.substring(12));
    } else if (!arg.startsWith('-')) {
      url = arg;
    }
  }

  if (url == null) {
    print(
        'Usage: flutter-skill plan <url> [--output=test-plan.yaml] [--format=yaml|json] [--depth=3]');
    print('');
    print('Options:');
    print('  --output=PATH      Output file path (default: stdout)');
    print('  --format=FORMAT    Output format: yaml or json (default: yaml)');
    print('  --depth=N          Max crawl depth (default: 3)');
    print('  --cdp-port=N       Chrome DevTools port (default: 9222)');
    print('  --no-headless      Run Chrome with UI visible');
    print('  --no-security      Exclude security test cases');
    print('  --no-a11y          Exclude accessibility test cases');
    print('  --max-pages=N      Max pages to visit (default: 10)');
    print('  --max-links=N      Max links to follow per page (default: 20)');
    exit(1);
  }

  outputPath ??= format == 'json' ? 'test-plan.json' : 'test-plan.yaml';

  print('📋 flutter-skill plan — AI Test Plan Generator');
  print('');
  print('   URL: $url');
  print('   Depth: $depth');
  print('   Format: $format');
  print('   Output: $outputPath');
  print('');

  final generator = _PlanGenerator(
    startUrl: url,
    maxDepth: depth,
    cdpPort: cdpPort,
    headless: headless,
    includeSecurity: includeSecurity,
    includeA11y: includeA11y,
    maxPages: maxPages,
    maxLinks: maxLinks,
  );

  final plan = await generator.generate();

  String output;
  if (format == 'json') {
    output = const JsonEncoder.withIndent('  ').convert(plan);
  } else {
    output = _toYaml(plan);
  }

  final file = File(outputPath);
  await file.writeAsString(output);
  print('');
  print('✅ Test plan saved to $outputPath');

  // Print summary
  final summary = plan['test_plan']?['summary'] as Map<String, dynamic>?;
  if (summary != null) {
    print('');
    print('═══════════════════════════════════════════════');
    print('  📊 Summary');
    print('  Total tests: ${summary['total_tests']}');
    final byType = summary['by_type'] as Map<String, dynamic>?;
    if (byType != null) {
      print(
          '  By type: ${byType.entries.map((e) => '${e.key}: ${e.value}').join(', ')}');
    }
    print('  Estimated duration: ${summary['estimated_duration']}');
    print('═══════════════════════════════════════════════');
  }
}

/// XSS payloads for security test generation
const _xssPayloads = [
  '<script>alert(1)</script>',
  '"><img src=x onerror=alert(1)>',
  "javascript:alert(1)",
  "'-alert(1)-'",
  '<svg onload=alert(1)>',
];

/// Common invalid inputs for negative testing
const _negativeInputs = {
  'empty': '',
  'whitespace': '   ',
  'very_long':
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  'special_chars': '!@#\$%^&*()_+-=[]{}|;:\'",.<>?/',
  'sql_injection': "'; DROP TABLE users; --",
  'emoji': '🎉🔥💀🚀',
  'null_bytes': '\x00\x01\x02',
  'negative_number': '-1',
  'huge_number': '99999999999999999999',
  'html_tags': '<b>bold</b><script>alert(1)</script>',
};

/// Sample valid inputs by field type
const _validInputsByType = {
  'email': 'test@example.com',
  'password': 'Password123!',
  'text': 'Test input',
  'number': '42',
  'tel': '+1234567890',
  'url': 'https://example.com',
  'search': 'search query',
  'date': '2026-01-15',
  'time': '14:30',
};

class _PlanGenerator {
  final String startUrl;
  final int maxDepth;
  final int cdpPort;
  final bool headless;
  final bool includeSecurity;
  final bool includeA11y;
  final int maxPages;
  final int maxLinks;

  late CdpDriver _cdp;
  final Map<String, _PageInfo> _visited = {};
  final List<(String, int)> _queue = [];

  _PlanGenerator({
    required this.startUrl,
    required this.maxDepth,
    required this.cdpPort,
    required this.headless,
    required this.includeSecurity,
    required this.includeA11y,
    required this.maxPages,
    required this.maxLinks,
  });

  Future<Map<String, dynamic>> generate() async {
    print('📡 Launching Chrome and connecting via CDP...');
    _cdp = CdpDriver(
      url: startUrl,
      port: cdpPort,
      launchChrome: cdpPort == 0,
      headless: headless,
    );
    await _cdp.connect();
    print('✅ Connected');

    // Crawl pages
    _queue.add((startUrl, 0));

    while (_queue.isNotEmpty) {
      if (_visited.length >= maxPages) break;

      final (pageUrl, currentDepth) = _queue.removeAt(0);
      final normalizedUrl = _normalizeUrl(pageUrl);

      if (_visited.containsKey(normalizedUrl)) continue;
      if (currentDepth > maxDepth) continue;

      print('🔍 [$currentDepth/$maxDepth] Analyzing: $pageUrl');
      final info = await _analyzePage(pageUrl, currentDepth);
      _visited[normalizedUrl] = info;

      if (currentDepth < maxDepth) {
        final linksToFollow = info.links.take(maxLinks).toList();
        for (final link in linksToFollow) {
          final normLink = _normalizeUrl(link);
          if (!_visited.containsKey(normLink) &&
              _isSameOrigin(link, startUrl)) {
            _queue.add((link, currentDepth + 1));
          }
        }
      }
    }

    await _cdp.disconnect();

    // Generate test plan
    return _buildTestPlan();
  }

  Future<_PageInfo> _analyzePage(String pageUrl, int depth) async {
    final info = _PageInfo(url: pageUrl, depth: depth);

    try {
      await _cdp.call('Page.navigate', {'url': pageUrl});
      await Future.delayed(const Duration(seconds: 2));

      // Get interactive elements
      final structured = await _cdp.getInteractiveElementsStructured();
      final elements = (structured['elements'] as List<dynamic>?) ?? [];

      for (final el in elements) {
        if (el is! Map<String, dynamic>) continue;
        final type = el['type'] as String? ?? '';
        final actions = (el['actions'] as List?)?.cast<String>() ?? [];
        final text = el['text'] as String? ?? '';
        final ref = el['ref'] as String? ?? '';
        final selector = el['selector'] as String? ?? '';
        final attrs = el['attributes'] as Map<String, dynamic>? ?? {};
        final inputType = attrs['type'] as String? ?? 'text';
        final name = attrs['name'] as String? ?? '';
        final placeholder = attrs['placeholder'] as String? ?? '';

        if (actions.contains('enter_text') &&
            (type == 'input' || type == 'textarea')) {
          info.formFields.add(_FieldInfo(
            selector: selector,
            ref: ref,
            type: inputType,
            name: name,
            placeholder: placeholder,
            text: text,
          ));
        } else if (actions.contains('tap') &&
            (type == 'button' || type == 'a' || ref.startsWith('button:'))) {
          info.buttons.add(_ButtonInfo(
            ref: ref,
            text: text,
            type: type,
            selector: selector,
          ));
        }
      }

      // Discover links
      final linksResult = await _cdp.evaluate('''
        JSON.stringify(
          Array.from(document.querySelectorAll('a[href]'))
            .map(a => a.href)
            .filter(h => h && !h.startsWith('javascript:') && !h.startsWith('mailto:'))
        )
      ''');
      final linksJson = linksResult['result']?['value'] as String?;
      if (linksJson != null) {
        info.links = (jsonDecode(linksJson) as List).cast<String>();
      }

      // Check for auth indicators
      final pageSource = await _cdp
          .evaluate('document.documentElement.outerHTML.substring(0, 5000)');
      final html =
          (pageSource['result']?['value'] as String? ?? '').toLowerCase();
      info.hasLoginForm = html.contains('password') &&
          (html.contains('login') ||
              html.contains('sign in') ||
              html.contains('email'));
      info.hasPagination = html.contains('pagination') ||
          html.contains('next page') ||
          html.contains('page-number') ||
          html.contains('load more');

      // Check for lists/scrollable content
      final listResult = await _cdp.evaluate('''
        JSON.stringify({
          lists: document.querySelectorAll('ul, ol, table, [role="list"], [role="grid"]').length,
          scrollable: document.querySelectorAll('[style*="overflow"], .scroll, .scrollable').length
        })
      ''');
      final listJson = listResult['result']?['value'] as String?;
      if (listJson != null) {
        final listData = jsonDecode(listJson) as Map<String, dynamic>;
        info.hasLists = (listData['lists'] as int? ?? 0) > 0;
        info.hasScrollable = (listData['scrollable'] as int? ?? 0) > 0;
      }

      // Check for accessibility issues
      if (includeA11y) {
        final a11yResult = await _cdp.evaluate('''
          JSON.stringify({
            imagesWithoutAlt: document.querySelectorAll('img:not([alt])').length,
            inputsWithoutLabel: document.querySelectorAll('input:not([aria-label]):not([id])').length,
            missingLang: !document.documentElement.hasAttribute('lang'),
            missingTitle: !document.title
          })
        ''');
        final a11yJson = a11yResult['result']?['value'] as String?;
        if (a11yJson != null) {
          final a11y = jsonDecode(a11yJson) as Map<String, dynamic>;
          if ((a11y['imagesWithoutAlt'] as int? ?? 0) > 0) {
            info.a11yIssues.add('images_without_alt');
          }
          if ((a11y['inputsWithoutLabel'] as int? ?? 0) > 0) {
            info.a11yIssues.add('inputs_without_label');
          }
          if (a11y['missingLang'] == true) {
            info.a11yIssues.add('missing_lang');
          }
          if (a11y['missingTitle'] == true) {
            info.a11yIssues.add('missing_title');
          }
        }
      }

      print(
          '   📦 ${info.formFields.length} fields, ${info.buttons.length} buttons, ${info.links.length} links');
    } catch (e) {
      print('   ❌ Error analyzing page: $e');
    }

    return info;
  }

  Map<String, dynamic> _buildTestPlan() {
    final pages = <Map<String, dynamic>>[];
    int totalPositive = 0, totalNegative = 0, totalSecurity = 0, totalA11y = 0;

    for (final entry in _visited.entries) {
      final info = entry.value;
      final tests = <Map<String, dynamic>>[];
      final pagePath = Uri.parse(info.url).path;

      // Generate form tests
      if (info.formFields.isNotEmpty) {
        // Positive: fill all fields with valid data and submit
        final positiveSteps = <Map<String, dynamic>>[];
        for (final field in info.formFields) {
          final validValue =
              _validInputsByType[field.type] ?? 'Test input value';
          final key = field.name.isNotEmpty
              ? field.name
              : field.placeholder.isNotEmpty
                  ? field.placeholder
                  : field.ref;
          positiveSteps.add({
            'tool': 'smart_enter_text',
            'args': {'key': key, 'value': validValue}
          });
        }
        // Find submit button
        final submitBtn = info.buttons
            .where((b) =>
                b.text.toLowerCase().contains('submit') ||
                b.text.toLowerCase().contains('sign') ||
                b.text.toLowerCase().contains('login') ||
                b.text.toLowerCase().contains('send') ||
                b.text.toLowerCase().contains('save') ||
                b.text.toLowerCase().contains('create'))
            .firstOrNull;
        if (submitBtn != null) {
          positiveSteps.add({
            'tool': 'smart_tap',
            'args': {'text': submitBtn.text}
          });
        }
        positiveSteps.add({
          'tool': 'smart_assert',
          'args': {'type': 'no_error'}
        });

        tests.add({
          'name': 'Submit form with valid data on $pagePath',
          'type': 'positive',
          'steps': positiveSteps,
        });
        totalPositive++;

        // Negative: each field with invalid inputs
        for (final field in info.formFields) {
          final key = field.name.isNotEmpty
              ? field.name
              : field.placeholder.isNotEmpty
                  ? field.placeholder
                  : field.ref;

          // Empty input
          tests.add({
            'name': 'Empty input for "$key" on $pagePath',
            'type': 'negative',
            'steps': [
              {
                'tool': 'smart_enter_text',
                'args': {'key': key, 'value': ''}
              },
              if (submitBtn != null)
                {
                  'tool': 'smart_tap',
                  'args': {'text': submitBtn.text}
                },
              {
                'tool': 'smart_assert',
                'args': {'type': 'visible', 'text': 'required'}
              },
            ],
          });
          totalNegative++;

          // Very long input
          tests.add({
            'name': 'Very long input for "$key" on $pagePath',
            'type': 'negative',
            'steps': [
              {
                'tool': 'smart_enter_text',
                'args': {'key': key, 'value': _negativeInputs['very_long']!}
              },
              {
                'tool': 'smart_assert',
                'args': {'type': 'no_error'}
              },
            ],
          });
          totalNegative++;

          // Special characters
          tests.add({
            'name': 'Special characters in "$key" on $pagePath',
            'type': 'negative',
            'steps': [
              {
                'tool': 'smart_enter_text',
                'args': {'key': key, 'value': _negativeInputs['special_chars']!}
              },
              {
                'tool': 'smart_assert',
                'args': {'type': 'no_error'}
              },
            ],
          });
          totalNegative++;

          // Security: XSS in each field
          if (includeSecurity) {
            for (final payload in _xssPayloads.take(2)) {
              tests.add({
                'name': 'XSS payload in "$key" on $pagePath',
                'type': 'security',
                'steps': [
                  {
                    'tool': 'smart_enter_text',
                    'args': {'key': key, 'value': payload}
                  },
                  if (submitBtn != null)
                    {
                      'tool': 'smart_tap',
                      'args': {'text': submitBtn.text}
                    },
                  {
                    'tool': 'smart_assert',
                    'args': {'type': 'no_alert'}
                  },
                ],
              });
              totalSecurity++;
            }

            // SQL injection
            tests.add({
              'name': 'SQL injection in "$key" on $pagePath',
              'type': 'security',
              'steps': [
                {
                  'tool': 'smart_enter_text',
                  'args': {
                    'key': key,
                    'value': _negativeInputs['sql_injection']!
                  }
                },
                {
                  'tool': 'smart_assert',
                  'args': {'type': 'no_error'}
                },
              ],
            });
            totalSecurity++;
          }
        }
      }

      // Button click tests
      for (final btn in info.buttons) {
        tests.add({
          'name': 'Click "${btn.text}" button on $pagePath',
          'type': 'positive',
          'steps': [
            {
              'tool': 'smart_tap',
              'args': {'text': btn.text}
            },
            {
              'tool': 'smart_assert',
              'args': {'type': 'no_error'}
            },
          ],
        });
        totalPositive++;
      }

      // Navigation link tests
      for (final link in info.links.take(5)) {
        final linkPath = Uri.parse(link).path;
        tests.add({
          'name': 'Navigate to $linkPath from $pagePath',
          'type': 'positive',
          'steps': [
            {
              'tool': 'navigate',
              'args': {'url': link}
            },
            {
              'tool': 'smart_assert',
              'args': {'type': 'no_error'}
            },
          ],
        });
        totalPositive++;
      }

      // Auth tests
      if (info.hasLoginForm) {
        tests.add({
          'name': 'Login with valid credentials on $pagePath',
          'type': 'positive',
          'steps': [
            {
              'tool': 'smart_enter_text',
              'args': {'key': 'email', 'value': 'test@example.com'}
            },
            {
              'tool': 'smart_enter_text',
              'args': {'key': 'password', 'value': 'Password123!'}
            },
            {
              'tool': 'smart_tap',
              'args': {'text': 'Sign In'}
            },
            {
              'tool': 'smart_assert',
              'args': {'type': 'navigation'}
            },
          ],
        });
        totalPositive++;

        tests.add({
          'name': 'Login with invalid credentials on $pagePath',
          'type': 'negative',
          'steps': [
            {
              'tool': 'smart_enter_text',
              'args': {'key': 'email', 'value': 'invalid@test.com'}
            },
            {
              'tool': 'smart_enter_text',
              'args': {'key': 'password', 'value': 'wrongpass'}
            },
            {
              'tool': 'smart_tap',
              'args': {'text': 'Sign In'}
            },
            {
              'tool': 'smart_assert',
              'args': {'type': 'visible', 'text': 'error'}
            },
          ],
        });
        totalNegative++;
      }

      // Pagination/scroll tests
      if (info.hasPagination || info.hasLists || info.hasScrollable) {
        tests.add({
          'name': 'Scroll down and load more content on $pagePath',
          'type': 'positive',
          'steps': [
            {
              'tool': 'smart_scroll',
              'args': {'direction': 'down', 'amount': 500}
            },
            {
              'tool': 'smart_assert',
              'args': {'type': 'no_error'}
            },
          ],
        });
        totalPositive++;

        if (info.hasPagination) {
          tests.add({
            'name': 'Navigate to next page on $pagePath',
            'type': 'positive',
            'steps': [
              {
                'tool': 'smart_tap',
                'args': {'text': 'Next'}
              },
              {
                'tool': 'smart_assert',
                'args': {'type': 'no_error'}
              },
            ],
          });
          totalPositive++;
        }
      }

      // Accessibility tests
      if (includeA11y && info.a11yIssues.isNotEmpty) {
        for (final issue in info.a11yIssues) {
          tests.add({
            'name': 'A11y: Fix $issue on $pagePath',
            'type': 'a11y',
            'steps': [
              {
                'tool': 'accessibility_audit',
                'args': {'check': issue}
              },
            ],
          });
          totalA11y++;
        }
      }

      if (tests.isNotEmpty) {
        pages.add({
          'url': pagePath.isEmpty ? '/' : pagePath,
          'tests': tests,
        });
      }
    }

    final totalTests =
        totalPositive + totalNegative + totalSecurity + totalA11y;
    final estimatedMinutes = (totalTests * 4 / 60).ceil();

    return {
      'test_plan': {
        'app_url': startUrl,
        'generated_at': DateTime.now().toUtc().toIso8601String(),
        'pages': pages,
        'summary': {
          'total_tests': totalTests,
          'by_type': {
            'positive': totalPositive,
            'negative': totalNegative,
            'security': totalSecurity,
            'a11y': totalA11y,
          },
          'estimated_duration': '$estimatedMinutes min',
        },
      },
    };
  }

  String _normalizeUrl(String url) {
    try {
      final uri = Uri.parse(url);
      return uri.replace(fragment: '').toString().replaceAll(RegExp(r'/$'), '');
    } catch (_) {
      return url;
    }
  }

  bool _isSameOrigin(String url, String baseUrl) {
    try {
      return Uri.parse(url).host == Uri.parse(baseUrl).host;
    } catch (_) {
      return false;
    }
  }
}

class _PageInfo {
  final String url;
  final int depth;
  List<_FieldInfo> formFields = [];
  List<_ButtonInfo> buttons = [];
  List<String> links = [];
  bool hasLoginForm = false;
  bool hasPagination = false;
  bool hasLists = false;
  bool hasScrollable = false;
  List<String> a11yIssues = [];

  _PageInfo({required this.url, required this.depth});
}

class _FieldInfo {
  final String selector;
  final String ref;
  final String type;
  final String name;
  final String placeholder;
  final String text;

  _FieldInfo({
    required this.selector,
    required this.ref,
    required this.type,
    required this.name,
    required this.placeholder,
    required this.text,
  });
}

class _ButtonInfo {
  final String ref;
  final String text;
  final String type;
  final String selector;

  _ButtonInfo({
    required this.ref,
    required this.text,
    required this.type,
    required this.selector,
  });
}

/// Convert a map to YAML-like string
String _toYaml(Map<String, dynamic> data, {int indent = 0}) {
  final buffer = StringBuffer();
  _writeYaml(buffer, data, indent);
  return buffer.toString();
}

void _writeYaml(StringBuffer buffer, dynamic value, int indent) {
  final prefix = '  ' * indent;

  if (value is Map<String, dynamic>) {
    for (final entry in value.entries) {
      if (entry.value is Map || entry.value is List) {
        buffer.writeln('$prefix${entry.key}:');
        _writeYaml(buffer, entry.value, indent + 1);
      } else {
        buffer.writeln('$prefix${entry.key}: ${_yamlValue(entry.value)}');
      }
    }
  } else if (value is List) {
    for (final item in value) {
      if (item is Map<String, dynamic>) {
        // Check if it's a simple flat map (for steps)
        final isFlat = item.values.every((v) => v is! Map && v is! List);
        if (isFlat && item.length <= 3) {
          buffer.writeln(
              '$prefix- {${item.entries.map((e) => '${e.key}: ${_yamlValue(e.value)}').join(', ')}}');
        } else {
          final entries = item.entries.toList();
          for (var i = 0; i < entries.length; i++) {
            final e = entries[i];
            if (i == 0) {
              if (e.value is Map || e.value is List) {
                buffer.writeln('$prefix- ${e.key}:');
                _writeYaml(buffer, e.value, indent + 2);
              } else {
                buffer.writeln('$prefix- ${e.key}: ${_yamlValue(e.value)}');
              }
            } else {
              if (e.value is Map || e.value is List) {
                buffer.writeln('$prefix  ${e.key}:');
                _writeYaml(buffer, e.value, indent + 2);
              } else {
                buffer.writeln('$prefix  ${e.key}: ${_yamlValue(e.value)}');
              }
            }
          }
        }
      } else {
        buffer.writeln('$prefix- ${_yamlValue(item)}');
      }
    }
  }
}

String _yamlValue(dynamic value) {
  if (value == null) return 'null';
  if (value is bool) return value.toString();
  if (value is num) return value.toString();
  if (value is String) {
    if (value.contains('"') ||
        value.contains(':') ||
        value.contains('#') ||
        value.contains("'") ||
        value.contains('{') ||
        value.contains('}') ||
        value.contains('[') ||
        value.contains(']') ||
        value.contains('<') ||
        value.contains('>') ||
        value.contains('\n') ||
        value.contains(',')) {
      // Use double quotes with escaping
      return '"${value.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"';
    }
    if (value.isEmpty) return '""';
    return '"$value"';
  }
  return value.toString();
}
