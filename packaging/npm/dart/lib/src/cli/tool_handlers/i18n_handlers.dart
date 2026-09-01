part of '../server.dart';

extension _I18nHandlers on FlutterMcpServer {
  /// i18n / multi-language testing tools
  /// Returns null if the tool is not handled.
  Future<dynamic> _handleI18nTools(
      String name, Map<String, dynamic> args) async {
    if (name == 'set_locale') {
      return _handleSetLocale(args);
    }
    if (name == 'verify_translations') {
      return _handleVerifyTranslations(args);
    }
    if (name == 'i18n_snapshot') {
      return _handleI18nSnapshot(args);
    }
    return null;
  }

  Future<Map<String, dynamic>> _handleSetLocale(
      Map<String, dynamic> args) async {
    final locale = args['locale'] as String;
    final method = args['platform_method'] as String?;

    // Auto-detect method based on connection type
    final effectiveMethod = method ?? _detectLocaleMethod();

    switch (effectiveMethod) {
      case 'cdp_emulation':
        return _setLocaleCdp(locale);
      case 'bridge_method':
        return _setLocaleBridge(locale);
      case 'deep_link':
        return _setLocaleDeepLink(locale);
      default:
        return _setLocaleCdp(locale);
    }
  }

  String _detectLocaleMethod() {
    if (_cdpDriver != null) return 'cdp_emulation';
    if (_client is BridgeDriver) return 'bridge_method';
    return 'deep_link';
  }

  Future<Map<String, dynamic>> _setLocaleCdp(String locale) async {
    final cdp = _cdpDriver;
    if (cdp == null) {
      return {'success': false, 'error': 'No CDP connection available'};
    }
    try {
      await cdp.call('Emulation.setLocaleOverride', {'locale': locale});
      // Reload to apply locale change
      await cdp.call('Page.reload', {});
      return {
        'success': true,
        'locale': locale,
        'method': 'cdp_emulation',
        'message': 'Locale set to $locale via CDP Emulation. Page reloaded.'
      };
    } catch (e) {
      return {
        'success': false,
        'error': e.toString(),
        'method': 'cdp_emulation'
      };
    }
  }

  Future<Map<String, dynamic>> _setLocaleBridge(String locale) async {
    final client = _client;
    if (client == null || client is! BridgeDriver) {
      return {'success': false, 'error': 'No bridge connection available'};
    }
    try {
      final result = await client.callTool('set_locale', {'locale': locale});
      return {
        'success': true,
        'locale': locale,
        'method': 'bridge_method',
        'result': result,
        'message': 'Locale set to $locale via bridge method.'
      };
    } catch (e) {
      return {
        'success': false,
        'error': e.toString(),
        'method': 'bridge_method'
      };
    }
  }

  Future<Map<String, dynamic>> _setLocaleDeepLink(String locale) async {
    // Attempt to use deep link to set locale
    // This works with apps that support locale switching via URL scheme
    return {
      'success': false,
      'error':
          'Deep link locale switching requires app-specific configuration. '
              'Consider using cdp_emulation or bridge_method instead.',
      'method': 'deep_link',
      'locale': locale,
    };
  }

  Future<Map<String, dynamic>> _handleVerifyTranslations(
      Map<String, dynamic> args) async {
    final expectedLocale = args['expected_locale'] as String;
    final checkOverflow = args['check_overflow'] as bool? ?? true;
    final checkUntranslated = args['check_untranslated'] as bool? ?? true;

    final issues = <Map<String, dynamic>>[];
    final isNonEnglish = !expectedLocale.toLowerCase().startsWith('en');

    // Get page text content via CDP or bridge
    String? pageText;

    final cdp = _cdpDriver;
    if (cdp != null) {
      try {
        // Get all visible text from page
        final textResult = await cdp.call('Runtime.evaluate', {
          'expression': 'document.body.innerText',
          'returnByValue': true,
        });
        pageText = (textResult['result'] as Map<String, dynamic>?)?['value']
            as String?;

        if (checkOverflow) {
          // Check for elements with overflow hidden and content truncation
          final overflowResult = await cdp.call('Runtime.evaluate', {
            'expression': '''
              (function() {
                const issues = [];
                const allElements = document.querySelectorAll('*');
                for (const el of allElements) {
                  const style = window.getComputedStyle(el);
                  if (style.overflow === 'hidden' || style.textOverflow === 'ellipsis') {
                    if (el.scrollWidth > el.clientWidth || el.scrollHeight > el.clientHeight) {
                      issues.push({
                        tag: el.tagName,
                        text: el.textContent?.substring(0, 100) || '',
                        scrollWidth: el.scrollWidth,
                        clientWidth: el.clientWidth,
                        scrollHeight: el.scrollHeight,
                        clientHeight: el.clientHeight,
                      });
                    }
                  }
                }
                return JSON.stringify(issues);
              })()
            ''',
            'returnByValue': true,
          });
          final overflowJson = (overflowResult['result']
              as Map<String, dynamic>?)?['value'] as String?;
          if (overflowJson != null) {
            final overflowIssues =
                jsonDecode(overflowJson) as List<dynamic>? ?? [];
            for (final issue in overflowIssues) {
              issues.add({
                'type': 'text_overflow',
                'element': issue['tag'],
                'text_preview': issue['text'],
                'scroll_width': issue['scrollWidth'],
                'client_width': issue['clientWidth'],
                'scroll_height': issue['scrollHeight'],
                'client_height': issue['clientHeight'],
              });
            }
          }
        }
      } catch (e) {
        return {'success': false, 'error': 'CDP evaluation failed: $e'};
      }
    } else if (_client != null) {
      // Bridge mode: get text from interactive elements
      try {
        final elements = await _client!.getInteractiveElements();
        pageText = _extractTextFromTree(elements);
      } catch (e) {
        return {'success': false, 'error': 'Failed to get page text: $e'};
      }
    } else {
      return {'success': false, 'error': 'No connection available'};
    }

    // Check for untranslated strings (English text in non-English locale)
    if (checkUntranslated && isNonEnglish && pageText != null) {
      // Split text into segments and check for English-heavy segments
      final lines = pageText.split('\n').where((l) => l.trim().isNotEmpty);
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        // Count ASCII letter ratio — high ratio in non-English locale suggests untranslated
        final asciiLetters = trimmed.runes
            .where((r) => (r >= 65 && r <= 90) || (r >= 97 && r <= 122))
            .length;
        final totalChars = trimmed.runes.length;
        if (totalChars > 3 && asciiLetters / totalChars > 0.8) {
          // Likely untranslated English text
          issues.add({
            'type': 'possibly_untranslated',
            'text': trimmed.length > 100
                ? '${trimmed.substring(0, 100)}...'
                : trimmed,
            'ascii_ratio': (asciiLetters / totalChars * 100).round(),
          });
        }
      }
    }

    return {
      'success': true,
      'expected_locale': expectedLocale,
      'issues_found': issues.length,
      'issues': issues,
      'checks_performed': {
        'overflow': checkOverflow,
        'untranslated': checkUntranslated && isNonEnglish,
      },
    };
  }

  String _extractTextFromTree(dynamic tree) {
    if (tree == null) return '';
    if (tree is String) return tree;
    if (tree is Map) {
      final buf = StringBuffer();
      if (tree.containsKey('label')) buf.writeln(tree['label']);
      if (tree.containsKey('text')) buf.writeln(tree['text']);
      if (tree.containsKey('value')) buf.writeln(tree['value']);
      final children = tree['children'];
      if (children is List) {
        for (final child in children) {
          buf.write(_extractTextFromTree(child));
        }
      }
      return buf.toString();
    }
    if (tree is List) {
      return tree.map(_extractTextFromTree).join('\n');
    }
    return tree.toString();
  }

  Future<Map<String, dynamic>> _handleI18nSnapshot(
      Map<String, dynamic> args) async {
    final locales = (args['locales'] as List<dynamic>).cast<String>();
    final saveDir = args['save_dir'] as String? ?? './i18n-snapshots';

    final dir = Directory(saveDir);
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }

    final snapshots = <Map<String, dynamic>>[];
    final errors = <Map<String, dynamic>>[];

    for (final locale in locales) {
      // Set locale
      final setResult = await _handleSetLocale({'locale': locale});
      if (setResult['success'] != true) {
        errors.add({'locale': locale, 'error': setResult['error']});
        continue;
      }

      // Wait a moment for locale to apply
      await Future.delayed(const Duration(milliseconds: 500));

      // Take screenshot
      String? imagePath;
      final cdp = _cdpDriver;
      if (cdp != null) {
        try {
          final screenshotResult = await cdp.call('Page.captureScreenshot', {
            'format': 'png',
          });
          final base64Data = screenshotResult['data'] as String?;
          if (base64Data != null) {
            final filePath = '$saveDir/snapshot_$locale.png';
            final file = File(filePath);
            await file.writeAsBytes(base64Decode(base64Data));
            imagePath = filePath;
          }
        } catch (e) {
          errors.add({'locale': locale, 'error': 'Screenshot failed: $e'});
          continue;
        }
      } else if (_client != null) {
        try {
          final screenshot = await _client!.takeScreenshot();
          if (screenshot is String && screenshot.isNotEmpty) {
            final filePath = '$saveDir/snapshot_$locale.png';
            final file = File(filePath);
            await file.writeAsBytes(base64Decode(screenshot));
            imagePath = filePath;
          }
        } catch (e) {
          errors.add({'locale': locale, 'error': 'Screenshot failed: $e'});
          continue;
        }
      }

      snapshots.add({
        'locale': locale,
        'path': imagePath,
        'timestamp': DateTime.now().toIso8601String(),
      });
    }

    return {
      'success': true,
      'snapshots': snapshots,
      'errors': errors,
      'save_dir': saveDir,
      'total_locales': locales.length,
      'successful': snapshots.length,
      'failed': errors.length,
    };
  }
}
