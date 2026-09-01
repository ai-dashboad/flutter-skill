part of '../server.dart';

extension _DataDrivenHandlers on FlutterMcpServer {
  /// Handle data-driven testing tools.
  /// Returns null if the tool is not handled by this group.
  Future<dynamic> _handleDataDrivenTools(
      String name, Map<String, dynamic> args) async {
    switch (name) {
      case 'test_with_data':
        return _handleTestWithData(args);
      case 'generate_test_data':
        return _handleGenerateTestData(args);
      default:
        return null;
    }
  }

  Future<Map<String, dynamic>> _handleTestWithData(
      Map<String, dynamic> args) async {
    final dataSets = (args['data_sets'] as List?)?.cast<Map<String, dynamic>>();
    final actions = (args['actions'] as List?)?.cast<Map<String, dynamic>>();
    final resetBetween = args['reset_between'] as bool? ?? true;

    if (dataSets == null || dataSets.isEmpty) {
      return {
        'success': false,
        'error': 'data_sets is required and must not be empty'
      };
    }
    if (actions == null || actions.isEmpty) {
      return {
        'success': false,
        'error': 'actions is required and must not be empty'
      };
    }

    final results = <Map<String, dynamic>>[];
    int passed = 0;
    int failed = 0;

    for (int i = 0; i < dataSets.length; i++) {
      final dataSet = dataSets[i];
      final dataSetResults = <Map<String, dynamic>>[];
      bool dataSetPassed = true;

      // Reset app between data sets if requested (skip first)
      if (resetBetween && i > 0) {
        try {
          await _executeToolInner('hot_restart', {});
          await Future.delayed(const Duration(milliseconds: 500));
        } catch (_) {
          // Best effort reset
        }
      }

      for (final action in actions) {
        final tool = action['tool'] as String?;
        final arguments = action['arguments'] as Map<String, dynamic>? ?? {};

        if (tool == null) {
          dataSetResults.add({
            'success': false,
            'error': 'action missing "tool" field',
          });
          dataSetPassed = false;
          continue;
        }

        // Substitute {{field}} placeholders with data values
        final substitutedArgs = _substituteTemplateArgs(arguments, dataSet);

        try {
          final result = await _executeToolInner(tool, substitutedArgs);
          final success = result is Map ? result['success'] != false : true;
          dataSetResults.add({
            'tool': tool,
            'success': success,
            'result': result,
          });
          if (!success) dataSetPassed = false;
        } catch (e) {
          dataSetResults.add({
            'tool': tool,
            'success': false,
            'error': e.toString(),
          });
          dataSetPassed = false;
        }
      }

      if (dataSetPassed) {
        passed++;
      } else {
        failed++;
      }

      results.add({
        'data_set_index': i,
        'data': dataSet,
        'passed': dataSetPassed,
        'action_results': dataSetResults,
      });
    }

    return {
      'success': failed == 0,
      'total': dataSets.length,
      'passed': passed,
      'failed': failed,
      'results': results,
    };
  }

  Map<String, dynamic> _substituteTemplateArgs(
      Map<String, dynamic> args, Map<String, dynamic> data) {
    final result = <String, dynamic>{};
    for (final entry in args.entries) {
      result[entry.key] = _substituteValue(entry.value, data);
    }
    return result;
  }

  dynamic _substituteValue(dynamic value, Map<String, dynamic> data) {
    if (value is String) {
      return value.replaceAllMapped(
        RegExp(r'\{\{(\w+)\}\}'),
        (match) {
          final field = match.group(1)!;
          final replacement = data[field];
          return replacement?.toString() ?? match.group(0)!;
        },
      );
    } else if (value is Map<String, dynamic>) {
      return _substituteTemplateArgs(value, data);
    } else if (value is List) {
      return value.map((v) => _substituteValue(v, data)).toList();
    }
    return value;
  }

  Future<Map<String, dynamic>> _handleGenerateTestData(
      Map<String, dynamic> args) async {
    final type = args['type'] as String?;
    final count = args['count'] as int? ?? 5;
    final locale = args['locale'] as String? ?? 'en-US';

    if (type == null) {
      return {'success': false, 'error': 'type is required'};
    }

    final data = _generateData(type, count, locale);
    return {
      'success': true,
      'type': type,
      'count': data.length,
      'locale': locale,
      'data': data,
    };
  }

  List<dynamic> _generateData(String type, int count, String locale) {
    switch (type) {
      case 'email':
        return _generateEmails(count, locale);
      case 'name':
        return _generateNames(count, locale);
      case 'phone':
        return _generatePhones(count, locale);
      case 'address':
        return _generateAddresses(count, locale);
      case 'number':
        return _generateNumbers(count);
      case 'date':
        return _generateDates(count);
      case 'url':
        return _generateUrls(count);
      case 'password':
        return _generatePasswords(count);
      case 'text':
        return _generateTexts(count);
      case 'edge_cases':
        return _generateEdgeCases();
      default:
        return ['unsupported type: $type'];
    }
  }

  List<String> _generateEmails(int count, String locale) {
    final domains = [
      'gmail.com',
      'yahoo.com',
      'outlook.com',
      'test.com',
      'example.org'
    ];
    final prefixes = [
      'user',
      'test',
      'admin',
      'info',
      'hello',
      'john.doe',
      'jane_smith',
      'dev'
    ];
    final result = <String>[];
    for (int i = 0; i < count; i++) {
      result.add(
          '${prefixes[i % prefixes.length]}${i + 1}@${domains[i % domains.length]}');
    }
    return result;
  }

  List<String> _generateNames(int count, String locale) {
    final names = locale.startsWith('zh')
        ? ['张三', '李四', '王五', '赵六', '陈七', '刘八', '杨九', '黄十']
        : locale.startsWith('ja')
            ? ['田中太郎', '山田花子', '佐藤一郎', '鈴木次郎', '高橋三郎']
            : [
                'John Smith',
                'Jane Doe',
                'Alice Johnson',
                'Bob Williams',
                'Charlie Brown',
                'Diana Prince',
                'Edward Norton',
                'Fiona Apple'
              ];
    return List.generate(count, (i) => names[i % names.length]);
  }

  List<String> _generatePhones(int count, String locale) {
    final prefix = locale.startsWith('zh')
        ? '+86 1'
        : locale.startsWith('ja')
            ? '+81 '
            : '+1 ';
    return List.generate(count,
        (i) => '$prefix${(5551000 + i * 111).toString().padLeft(7, '0')}');
  }

  List<String> _generateAddresses(int count, String locale) {
    final streets = [
      '123 Main St',
      '456 Oak Ave',
      '789 Pine Rd',
      '321 Elm Blvd',
      '654 Maple Dr'
    ];
    final cities = [
      'New York, NY 10001',
      'Los Angeles, CA 90001',
      'Chicago, IL 60601',
      'Houston, TX 77001',
      'Phoenix, AZ 85001'
    ];
    return List.generate(count,
        (i) => '${streets[i % streets.length]}, ${cities[i % cities.length]}');
  }

  List<num> _generateNumbers(int count) {
    return [0, 1, -1, 42, 100, 999999, -999999, 3.14, 0.001, 2147483647]
        .take(count)
        .toList();
  }

  List<String> _generateDates(int count) {
    final base = DateTime(2024, 1, 15);
    return List.generate(count, (i) {
      final d = base.add(Duration(days: i * 30));
      return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    });
  }

  List<String> _generateUrls(int count) {
    final urls = [
      'https://example.com',
      'https://test.org/path?q=search',
      'http://localhost:3000',
      'https://sub.domain.co.uk/a/b/c',
      'ftp://files.example.com/doc.pdf',
    ];
    return List.generate(count, (i) => urls[i % urls.length]);
  }

  List<String> _generatePasswords(int count) {
    final passwords = [
      'P@ssw0rd!',
      'Str0ng#Pass123',
      'Test!ng_456',
      'S3cur3&Safe',
      'MyP@ss#2024',
    ];
    return List.generate(count, (i) => passwords[i % passwords.length]);
  }

  List<String> _generateTexts(int count) {
    final texts = [
      'Hello World',
      'The quick brown fox jumps over the lazy dog',
      'Lorem ipsum dolor sit amet',
      'Testing 123',
      'Café résumé naïve',
    ];
    return List.generate(count, (i) => texts[i % texts.length]);
  }

  List<Map<String, dynamic>> _generateEdgeCases() {
    return [
      {'label': 'empty_string', 'value': ''},
      {'label': 'whitespace_only', 'value': '   '},
      {'label': 'long_string', 'value': 'A' * 1001},
      {'label': 'unicode_emoji', 'value': '🎉🔥💯 Ünîcödé テスト 中文测试 العربية'},
      {'label': 'sql_injection', 'value': "'; DROP TABLE users; --"},
      {'label': 'xss_script', 'value': '<script>alert("xss")</script>'},
      {'label': 'xss_img', 'value': '<img src=x onerror=alert(1)>'},
      {'label': 'special_chars', 'value': r'!@#$%^&*()_+-=[]{}|;:,.<>?/~`'},
      {'label': 'newlines', 'value': 'line1\nline2\r\nline3\ttab'},
      {'label': 'null_bytes', 'value': 'before\x00after'},
      {'label': 'rtl_text', 'value': 'مرحبا بالعالم'},
      {'label': 'zero_width', 'value': 'zero\u200Bwidth\u200Bspace'},
      {'label': 'max_int', 'value': '9223372036854775807'},
      {'label': 'negative', 'value': '-99999999'},
      {'label': 'html_entities', 'value': '&lt;div&gt;&amp;nbsp;&lt;/div&gt;'},
    ];
  }
}
