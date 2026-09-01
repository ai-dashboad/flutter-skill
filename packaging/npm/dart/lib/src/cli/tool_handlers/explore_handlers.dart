part of '../server.dart';

extension _ExploreHandlers on FlutterMcpServer {
  /// Handle AI explore tools — designed for LLM-driven autonomous testing.
  /// Returns null if the tool is not handled by this group.
  Future<dynamic> _handleExploreTools(
      String name, Map<String, dynamic> args) async {
    switch (name) {
      case 'page_summary':
        return _handlePageSummary(args);
      case 'explore_actions':
        return _handleExploreActions(args);
      case 'boundary_test':
        return _handleBoundaryTest(args);
      case 'explore_report':
        return _handleExploreReport(args);
      default:
        return null;
    }
  }

  /// Get a compact semantic page summary via CDP Accessibility Tree.
  /// Returns structured data (~200 tokens) instead of raw screenshots (~4000 tokens).
  /// Includes: nav items, forms, buttons, headings, page features, console errors.
  Future<Map<String, dynamic>> _handlePageSummary(
      Map<String, dynamic> args) async {
    if (_cdpDriver == null) {
      return {'error': 'No CDP connection. Connect to a web app first.'};
    }

    final includeAxTree = args['include_ax_tree'] as bool? ?? false;
    final maxElements = args['max_elements'] as int? ?? 50;

    try {
      // Get page basics
      final urlResult = await _cdpDriver!.evaluate('window.location.href');
      final url = urlResult['result']?['value'] as String? ?? '';
      final titleResult = await _cdpDriver!.evaluate('document.title');
      final title = titleResult['result']?['value'] as String? ?? '';

      // Get Accessibility Tree (semantic page structure)
      final axNodes = await _getAxTree(maxElements);

      // Classify elements from AX tree
      final nav = <String>[];
      final forms = <List<Map<String, String>>>[];
      final buttons = <String>[];
      final headings = <String>[];
      final landmarks = <String>[];
      var links = 0;
      var inputs = 0;
      var hasSearch = false;
      var hasLogin = false;
      var hasPagination = false;
      var hasModal = false;

      var currentFormFields = <Map<String, String>>[];
      var insideNav = false;
      var insideNavDepth = 0;

      for (final node in axNodes) {
        final role = node['role'] as String;
        final name = node['name'] as String;
        final depth = node['depth'] as int;

        // Track navigation context
        if (role == 'navigation' || role == 'menubar') {
          insideNav = true;
          insideNavDepth = depth;
          landmarks.add(name.isNotEmpty ? 'nav:$name' : 'nav');
        } else if (insideNav && depth <= insideNavDepth) {
          insideNav = false;
        }

        switch (role) {
          case 'link':
            links++;
            if ((insideNav || depth <= 2) &&
                name.length > 1 &&
                name.length < 40 &&
                !RegExp(r'[\$€£¥]\d|CO₂|^\d+\s*(hours?|minutes?|days?)\s*ago')
                    .hasMatch(name)) {
              nav.add(name);
            }
            break;
          case 'button':
          case 'menuitem':
            if (name.isNotEmpty) buttons.add(name);
            break;
          case 'textbox':
          case 'searchbox':
          case 'spinbutton':
          case 'combobox':
            inputs++;
            final nameLower = name.toLowerCase();
            hasSearch = hasSearch ||
                role == 'searchbox' ||
                nameLower.contains('search');
            hasLogin = hasLogin || nameLower.contains('password');
            currentFormFields.add({
              'name': name.isNotEmpty ? name : '${role}_$inputs',
              'type': role == 'searchbox'
                  ? 'search'
                  : (nameLower.contains('password')
                      ? 'password'
                      : (nameLower.contains('email') ? 'email' : 'text')),
            });
            break;
          case 'heading':
            if (headings.length < 8 && name.isNotEmpty) {
              headings.add(name.length > 80 ? name.substring(0, 80) : name);
            }
            break;
          case 'dialog':
            hasModal = true;
            break;
          case 'banner':
          case 'main':
          case 'contentinfo':
          case 'complementary':
          case 'form':
            landmarks.add(name.isNotEmpty ? '$role:$name' : role);
            if (role == 'form' && currentFormFields.isNotEmpty) {
              forms.add(List.from(currentFormFields));
              currentFormFields = [];
            }
            break;
        }

        if (name.toLowerCase().contains('pagination') ||
            name.toLowerCase().contains('next page')) {
          hasPagination = true;
        }
      }

      // Flush remaining form fields
      if (currentFormFields.isNotEmpty) {
        forms.add(currentFormFields);
      }

      // Fallback: also get top-of-page links for non-semantic navbars
      if (nav.isEmpty) {
        try {
          final topLinks = await _cdpDriver!.evaluate(r'''
            JSON.stringify(
              Array.from(document.querySelectorAll('a[href]'))
                .filter(a => { const r = a.getBoundingClientRect(); return r.top >= 0 && r.top < 120 && r.height > 0; })
                .map(a => (a.textContent || '').trim())
                .filter(t => t && t.length > 0 && t.length < 50)
                .slice(0, 15)
            )
          ''');
          final v = topLinks['result']?['value'] as String?;
          if (v != null)
            nav.insertAll(0, (jsonDecode(v) as List).cast<String>());
        } catch (_) {}
      }

      // Check login via DOM (AX tree might miss type=password)
      if (!hasLogin) {
        final pw = await _cdpDriver!
            .evaluate('!!document.querySelector("input[type=password]")');
        hasLogin = pw['result']?['value'] == true;
      }

      // Collect console errors
      List<String> errors = [];
      try {
        final errResult = await _cdpDriver!
            .evaluate('JSON.stringify(window.__fs_explore_errors__ || [])');
        final v = errResult['result']?['value'] as String?;
        if (v != null) {
          errors = (jsonDecode(v) as List)
              .map((e) => '${e['type']}: ${e['message']}')
              .toList();
        }
      } catch (_) {}

      // Deduplicate nav
      final uniqueNav = <String>[];
      final seen = <String>{};
      for (final n in nav) {
        if (seen.add(n.toLowerCase())) uniqueNav.add(n);
        if (uniqueNav.length >= 15) break;
      }

      final summary = <String, dynamic>{
        'url': url,
        'title': title,
        'nav': uniqueNav,
        'forms': forms,
        'buttons': buttons.take(15).toList(),
        'headings': headings,
        'links': links,
        'inputs': inputs,
        'landmarks': landmarks,
        'features': {
          if (hasSearch) 'search': true,
          if (hasLogin) 'login': true,
          if (hasPagination) 'pagination': true,
          if (hasModal) 'modal': true,
        },
      };

      if (errors.isNotEmpty) summary['console_errors'] = errors;

      if (includeAxTree) {
        summary['ax_tree'] = axNodes.take(maxElements).toList();
      }

      return summary;
    } catch (e) {
      return {'error': 'Failed to summarize page: $e'};
    }
  }

  /// Execute a batch of explore actions (tap, fill, scroll, back, navigate).
  /// Designed for LLM to send multiple actions at once, reducing round-trips.
  Future<Map<String, dynamic>> _handleExploreActions(
      Map<String, dynamic> args) async {
    if (_cdpDriver == null) {
      return {'error': 'No CDP connection. Connect to a web app first.'};
    }

    final actions =
        (args['actions'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    if (actions.isEmpty) {
      return {
        'error': 'No actions provided. Use: [{"type":"tap","target":"..."}]'
      };
    }

    final results = <Map<String, dynamic>>[];
    final beforeUrl = await _cdpDriver!.evaluate('window.location.href');
    final startUrl = beforeUrl['result']?['value'] as String? ?? '';

    // Install error monitoring
    await _cdpDriver!.evaluate('''
      window.__fs_explore_errors__ = window.__fs_explore_errors__ || [];
      window.addEventListener('error', (e) => {
        window.__fs_explore_errors__.push({type:'error', message: e.message || String(e)});
      });
      window.addEventListener('unhandledrejection', (e) => {
        window.__fs_explore_errors__.push({type:'unhandledrejection', message: e.reason?.message || String(e.reason)});
      });
    ''');

    for (final action in actions) {
      final type = action['type'] as String? ?? '';
      final target = action['target'] as String? ?? '';
      final value = action['value'] as String?;

      try {
        switch (type) {
          case 'tap':
            final preUrl = await _cdpDriver!.evaluate('window.location.href');
            await _cdpDriver!.tap(ref: target);
            await Future.delayed(const Duration(milliseconds: 800));
            final postUrl = await _cdpDriver!.evaluate('window.location.href');
            final navigated =
                preUrl['result']?['value'] != postUrl['result']?['value'];
            results.add({
              'action': 'tap:$target',
              'success': true,
              if (navigated) 'navigated_to': postUrl['result']?['value'],
            });
            break;

          case 'fill':
            if (value == null) {
              results.add(
                  {'action': 'fill:$target', 'error': 'No value provided'});
              break;
            }
            try {
              await _cdpDriver!.fill(target, value);
            } catch (_) {
              // Fallback: try by name/placeholder/aria-label
              await _cdpDriver!.evaluate('''
                (() => {
                  const name = ${jsonEncode(target.replaceFirst(RegExp(r'^input:'), ''))};
                  const el = document.querySelector('[name="' + name + '"]')
                    || document.querySelector('[placeholder*="' + name + '"]')
                    || document.querySelector('[aria-label*="' + name + '"]')
                    || document.querySelector('#' + name);
                  if (el) { el.value = ${jsonEncode(value)}; el.dispatchEvent(new Event('input', {bubbles:true})); }
                })()
              ''');
            }
            results.add(
                {'action': 'fill:$target', 'success': true, 'value': value});
            break;

          case 'scroll':
            final px = target == 'up' ? -500 : 500;
            await _cdpDriver!
                .evaluate('window.scrollBy({top: $px, behavior: "smooth"})');
            await Future.delayed(const Duration(milliseconds: 300));
            results.add({'action': 'scroll:$target', 'success': true});
            break;

          case 'back':
            await _cdpDriver!.evaluate('window.history.back()');
            await Future.delayed(const Duration(seconds: 1));
            final newUrl = await _cdpDriver!.evaluate('window.location.href');
            results.add({
              'action': 'back',
              'success': true,
              'url': newUrl['result']?['value'],
            });
            break;

          case 'navigate':
            await _cdpDriver!.call('Page.navigate', {'url': target});
            await Future.delayed(const Duration(seconds: 2));
            results.add({'action': 'navigate:$target', 'success': true});
            break;

          case 'press':
            await _cdpDriver!.evaluate('''
              document.activeElement?.dispatchEvent(
                new KeyboardEvent('keydown', {key: ${jsonEncode(target)}, bubbles: true}))
            ''');
            results.add({'action': 'press:$target', 'success': true});
            break;

          case 'select':
            if (value != null) {
              await _cdpDriver!.evaluate('''
                (() => {
                  const el = document.querySelector('[aria-label*="${target.replaceFirst('select:', '')}"]') 
                    || document.querySelector('select[name*="${target.replaceFirst('select:', '')}"]');
                  if (el) { el.value = ${jsonEncode(value)}; el.dispatchEvent(new Event('change', {bubbles:true})); }
                })()
              ''');
            }
            results.add({'action': 'select:$target=$value', 'success': true});
            break;

          default:
            results.add({'action': type, 'error': 'Unknown action type'});
        }
      } catch (e) {
        results.add({
          'action': '$type:$target',
          'success': false,
          'error': e.toString(),
        });
      }
    }

    // Collect errors after all actions
    List<String> errors = [];
    try {
      final errResult = await _cdpDriver!
          .evaluate('JSON.stringify(window.__fs_explore_errors__ || [])');
      final v = errResult['result']?['value'] as String?;
      if (v != null) {
        final errList = jsonDecode(v) as List;
        errors = errList.map((e) => '${e['type']}: ${e['message']}').toList();
      }
      await _cdpDriver!.evaluate('window.__fs_explore_errors__ = []');
    } catch (_) {}

    // Get final page state
    final endUrl = await _cdpDriver!.evaluate('window.location.href');

    return {
      'results': results,
      'current_url': endUrl['result']?['value'] ?? startUrl,
      'started_at': startUrl,
      if (errors.isNotEmpty) 'console_errors': errors,
    };
  }

  /// Run boundary/security tests on a specific input field.
  /// Tests: empty, XSS, SQL injection, long strings, special chars, emoji.
  Future<Map<String, dynamic>> _handleBoundaryTest(
      Map<String, dynamic> args) async {
    if (_cdpDriver == null) {
      return {'error': 'No CDP connection. Connect to a web app first.'};
    }

    final target = args['target'] as String? ?? '';
    final customPayloads = (args['payloads'] as List?)?.cast<String>();

    if (target.isEmpty) {
      return {'error': 'target is required (e.g. "input:username")'};
    }

    final testCases = customPayloads != null
        ? {
            for (var i = 0; i < customPayloads.length; i++)
              'custom_$i': customPayloads[i]
          }
        : <String, String>{
            'empty': '',
            'xss_script': '<script>alert("xss")</script>',
            'xss_img': '"><img src=x onerror=alert(1)>',
            'xss_svg': '<svg onload=alert(1)>',
            'sql_single': "' OR '1'='1",
            'sql_drop': "'; DROP TABLE users; --",
            'long_256': 'a' * 256,
            'long_5000': 'a' * 5000,
            'emoji': '🎉🔥💀🦀👾',
            'unicode_rtl': '\u202Etest\u202C',
            'null_bytes': 'test\x00null',
            'newlines': 'line1\nline2\rline3',
            'special': '!@#\$%^&*(){}[]|\\:";\'<>?,./~`',
          };

    // Install error monitoring
    await _cdpDriver!.evaluate('''
      window.__fs_boundary_errors__ = [];
      window.addEventListener('error', (e) => {
        window.__fs_boundary_errors__.push({type:'error', message: e.message || String(e)});
      });
    ''');

    final results = <String, Map<String, dynamic>>{};
    final name = target.replaceFirst(RegExp(r'^input:'), '');

    for (final entry in testCases.entries) {
      try {
        // Fill the field
        try {
          await _cdpDriver!.fill(target, entry.value);
        } catch (_) {
          await _cdpDriver!.evaluate('''
            (() => {
              const el = document.querySelector('[name="${name}"]')
                || document.querySelector('[placeholder*="${name}"]')
                || document.querySelector('[aria-label*="${name}"]')
                || document.querySelector('#${name}');
              if (el) { el.value = ${jsonEncode(entry.value)}; el.dispatchEvent(new Event('input', {bubbles:true})); }
            })()
          ''');
        }
        await Future.delayed(const Duration(milliseconds: 200));

        // Check for JS errors
        final errResult = await _cdpDriver!
            .evaluate('JSON.stringify(window.__fs_boundary_errors__)');
        final errs =
            jsonDecode(errResult['result']?['value'] as String? ?? '[]')
                as List;
        await _cdpDriver!.evaluate('window.__fs_boundary_errors__ = []');

        // Check for XSS reflection
        bool xssReflected = false;
        if (entry.key.startsWith('xss')) {
          final check = await _cdpDriver!.evaluate('''
            document.documentElement.innerHTML.includes('onerror=alert') ||
            document.documentElement.innerHTML.includes('<svg onload')
          ''');
          xssReflected = check['result']?['value'] == true;
        }

        final result = <String, dynamic>{
          'passed': errs.isEmpty && !xssReflected
        };
        if (errs.isNotEmpty)
          result['errors'] = errs.map((e) => e['message']).toList();
        if (xssReflected) result['xss_reflected'] = true;
        results[entry.key] = result;
      } catch (e) {
        results[entry.key] = {'passed': false, 'error': e.toString()};
      }
    }

    final passed = results.values.where((r) => r['passed'] == true).length;
    final failed = results.length - passed;

    return {
      'target': target,
      'total': results.length,
      'passed': passed,
      'failed': failed,
      'results': results,
    };
  }

  /// Generate an HTML explore report from collected step data.
  Future<Map<String, dynamic>> _handleExploreReport(
      Map<String, dynamic> args) async {
    final steps = (args['steps'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final title = args['title'] as String? ?? 'Explore Report';
    final outputPath = args['output'] as String? ?? './explore-report.html';

    if (steps.isEmpty) {
      return {'error': 'No steps provided. Pass an array of step objects.'};
    }

    final buffer = StringBuffer();
    buffer.writeln('<!DOCTYPE html><html lang="en"><head>');
    buffer.writeln(
        '<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">');
    buffer.writeln('<title>$title</title>');
    buffer.writeln('<style>');
    buffer.writeln('''
      *{box-sizing:border-box;margin:0;padding:0}
      body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:#0f172a;color:#e2e8f0;padding:2rem}
      h1{font-size:2rem;margin-bottom:1rem}
      .stats{display:flex;gap:1rem;flex-wrap:wrap;margin:1rem 0}
      .stat{background:#1e293b;border-radius:12px;padding:1rem 1.5rem;min-width:120px}
      .stat b{font-size:1.8rem;display:block}
      .stat span{font-size:.85rem;color:#94a3b8}
      .step{background:#1e293b;border-radius:12px;padding:1.5rem;margin:1rem 0}
      .step-url{color:#60a5fa;font-weight:600;word-break:break-all}
      .action{padding:.2rem 0;font-family:monospace;font-size:.9rem}
      .bug{background:#7f1d1d33;border-left:3px solid #f87171;padding:.5rem .75rem;margin:.3rem 0;border-radius:4px;font-size:.9rem}
      .a11y{background:#78350f33;border-left:3px solid #fbbf24;padding:.5rem .75rem;margin:.3rem 0;border-radius:4px;font-size:.9rem}
      .pass{color:#4ade80} .fail{color:#f87171}
    ''');
    buffer.writeln('</style></head><body>');
    buffer.writeln('<h1>🤖 $title</h1>');
    buffer.writeln(
        '<p style="color:#94a3b8">Generated ${DateTime.now().toIso8601String()}</p>');

    // Stats
    var totalBugs = 0;
    var totalA11y = 0;
    for (final step in steps) {
      totalBugs += ((step['bugs'] as List?) ?? []).length;
      totalA11y += ((step['a11y_issues'] as List?) ?? []).length;
    }
    buffer.writeln('<div class="stats">');
    buffer.writeln(
        '<div class="stat"><b>${steps.length}</b><span>Steps</span></div>');
    buffer.writeln(
        '<div class="stat"><b class="fail">$totalBugs</b><span>Bugs</span></div>');
    buffer.writeln(
        '<div class="stat"><b style="color:#fbbf24">$totalA11y</b><span>A11y Issues</span></div>');
    buffer.writeln('</div>');

    for (int i = 0; i < steps.length; i++) {
      final step = steps[i];
      buffer.writeln('<div class="step">');
      buffer.writeln(
          '<div class="step-url">Step ${i + 1}: ${step['url'] ?? ''}</div>');

      final actions = (step['actions'] as List?) ?? [];
      for (final a in actions) {
        buffer.writeln('<div class="action">→ ${a}</div>');
      }

      final bugs = (step['bugs'] as List?) ?? [];
      for (final b in bugs) {
        buffer.writeln('<div class="bug">🐛 $b</div>');
      }

      final a11y = (step['a11y_issues'] as List?) ?? [];
      for (final issue in a11y) {
        buffer.writeln('<div class="a11y">♿ $issue</div>');
      }

      buffer.writeln('</div>');
    }

    buffer.writeln('</body></html>');

    final file = File(outputPath);
    await file.writeAsString(buffer.toString());

    return {
      'report': outputPath,
      'steps': steps.length,
      'bugs': totalBugs,
      'a11y_issues': totalA11y,
    };
  }

  /// Get compact accessibility tree via CDP
  Future<List<Map<String, dynamic>>> _getAxTree(int maxNodes) async {
    try {
      final result = await _cdpDriver!.call('Accessibility.getFullAXTree', {
        'depth': 8,
      });
      final nodes = (result['nodes'] as List?) ?? [];

      final parsed = <Map<String, dynamic>>[];
      final depthMap = <String, int>{};

      for (final node in nodes) {
        if (parsed.length >= maxNodes) break;

        final nodeId = node['nodeId'] as String? ?? '';
        final parentId = node['parentId'] as String? ?? '';
        final role = node['role']?['value'] as String? ?? '';
        final ignored = node['ignored'] as bool? ?? false;

        if (ignored) continue;
        // Skip non-semantic roles
        if (const {
          'none',
          'generic',
          'InlineTextBox',
          'StaticText',
          'paragraph',
          'group',
          'Section',
          'list',
          'listitem',
          'LineBreak',
          'LayoutTable',
          'LayoutTableRow',
          'LayoutTableCell'
        }.contains(role)) continue;

        final depth =
            depthMap.containsKey(parentId) ? depthMap[parentId]! + 1 : 0;
        depthMap[nodeId] = depth;

        String name = '';
        final nameObj = node['name'];
        if (nameObj is Map) name = (nameObj['value'] as String? ?? '').trim();

        parsed.add({
          'role': role,
          'name': name,
          'depth': depth,
        });
      }

      return parsed;
    } catch (e) {
      // Fallback
      final result = await _cdpDriver!.evaluate(r'''
        JSON.stringify(
          Array.from(document.querySelectorAll('a,button,input,select,textarea,[role],h1,h2,h3'))
            .filter(el => getComputedStyle(el).display !== 'none')
            .slice(0, 50)
            .map(el => ({
              role: el.getAttribute('role') || ({'A':'link','BUTTON':'button','INPUT':'textbox','SELECT':'combobox','TEXTAREA':'textbox','H1':'heading','H2':'heading','H3':'heading'}[el.tagName] || el.tagName.toLowerCase()),
              name: (el.getAttribute('aria-label') || el.textContent || '').trim().substring(0,80),
              depth: 2
            }))
        )
      ''');
      final v = result['result']?['value'] as String? ?? '[]';
      return (jsonDecode(v) as List).cast<Map<String, dynamic>>();
    }
  }
}
