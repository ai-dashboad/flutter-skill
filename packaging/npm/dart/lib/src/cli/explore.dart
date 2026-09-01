import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../bridge/cdp_driver.dart';
import 'ai_client.dart';

/// `flutter-skill explore` — AI Test Agent that autonomously explores a web app.
///
/// The agent uses a structured page summary (not screenshots) to minimize token usage.
/// LLM decides which actions to take based on nav items, forms, CTAs, and page structure.
/// Falls back to rule-based heuristics if no AI API key is configured.
///
/// Usage:
///   flutter-skill explore https://my-app.com [--depth=3] [--report=./report.html]
Future<void> runExplore(List<String> args) async {
  String? url;
  int maxSteps = 20;
  String reportPath = './explore-report.html';
  int cdpPort = 0;
  bool headless = true;
  int maxActionsPerStep = 5;
  bool noAi = false;

  for (final arg in args) {
    if (arg.startsWith('--max-steps=')) {
      maxSteps = int.parse(arg.substring(12));
    } else if (arg.startsWith('--report=')) {
      reportPath = arg.substring(9);
    } else if (arg.startsWith('--cdp-port=')) {
      cdpPort = int.parse(arg.substring(11));
    } else if (arg == '--no-headless') {
      headless = false;
    } else if (arg == '--no-ai') {
      noAi = true;
    } else if (arg.startsWith('--max-actions=')) {
      maxActionsPerStep = int.parse(arg.substring(14));
    } else if (!arg.startsWith('-')) {
      url = arg;
    }
  }

  if (url == null) {
    print(
        'Usage: flutter-skill explore <url> [--max-steps=20] [--report=./report.html]');
    print('');
    print('Options:');
    print('  --max-steps=N      Max exploration steps (default: 20)');
    print('  --max-actions=N    Max actions per LLM call (default: 5)');
    print('  --report=PATH      HTML report output path');
    print('  --cdp-port=N       Chrome DevTools port (0=auto)');
    print('  --no-headless      Run Chrome with UI visible');
    print('  --no-ai            Use rule-based heuristics only (no LLM)');
    exit(1);
  }

  final ai = noAi ? null : AiClient.fromEnv();
  final mode = ai != null ? 'AI Agent' : 'Rule-based';

  print('🤖 flutter-skill explore — $mode');
  print('');
  print('   URL: $url');
  print('   Max steps: $maxSteps');
  print('   Mode: $mode');
  print('   Report: $reportPath');
  print('');

  final agent = _ExploreAgent(
    startUrl: url,
    maxSteps: maxSteps,
    maxActionsPerStep: maxActionsPerStep,
    reportPath: reportPath,
    cdpPort: cdpPort,
    headless: headless,
    ai: ai,
  );

  await agent.run();
}

/// Compact page summary for LLM consumption (~200 tokens instead of ~4000)
class _PageSummary {
  final String url;
  final String title;
  final List<String> navItems;
  final List<Map<String, String>> forms;
  final List<String> ctaButtons;
  final List<String> otherButtons;
  final int linkCount;
  final int elementCount;
  final bool hasPagination;
  final bool hasSearch;
  final bool hasLogin;
  final bool hasModal;
  final List<String> headings;
  final List<String> consoleErrors;

  _PageSummary({
    required this.url,
    required this.title,
    required this.navItems,
    required this.forms,
    required this.ctaButtons,
    required this.otherButtons,
    required this.linkCount,
    required this.elementCount,
    required this.hasPagination,
    required this.hasSearch,
    required this.hasLogin,
    required this.hasModal,
    required this.headings,
    required this.consoleErrors,
  });

  Map<String, dynamic> toJson() => {
        'url': url,
        'title': title,
        if (navItems.isNotEmpty) 'nav': navItems,
        if (forms.isNotEmpty) 'forms': forms,
        if (ctaButtons.isNotEmpty) 'cta': ctaButtons,
        if (otherButtons.isNotEmpty) 'buttons': otherButtons.take(10).toList(),
        'links': linkCount,
        'elements': elementCount,
        if (hasPagination) 'pagination': true,
        if (hasSearch) 'search': true,
        if (hasLogin) 'login': true,
        if (hasModal) 'modal': true,
        if (headings.isNotEmpty) 'headings': headings.take(5).toList(),
        if (consoleErrors.isNotEmpty) 'errors': consoleErrors,
      };

  @override
  String toString() => jsonEncode(toJson());
}

/// An action the agent can take
class _ExploreAction {
  final String type; // tap, fill, scroll, navigate, back, boundary_test
  final String target; // ref or selector
  final String? value; // for fill actions
  final String? reason; // why this action

  _ExploreAction({
    required this.type,
    required this.target,
    this.value,
    this.reason,
  });

  factory _ExploreAction.fromJson(Map<String, dynamic> json) => _ExploreAction(
        type: json['type'] as String? ?? 'tap',
        target: json['target'] as String? ?? '',
        value: json['value'] as String?,
        reason: json['reason'] as String?,
      );

  @override
  String toString() =>
      '$type:$target${value != null ? '=$value' : ''}${reason != null ? ' ($reason)' : ''}';
}

/// Record of what happened during exploration
class _StepRecord {
  final int step;
  final String url;
  final _PageSummary summary;
  final List<_ExploreAction> actions;
  final List<String> results;
  final List<String> bugs;
  final List<String> a11yIssues;
  String? screenshotBase64;

  _StepRecord({
    required this.step,
    required this.url,
    required this.summary,
    required this.actions,
    required this.results,
    required this.bugs,
    required this.a11yIssues,
  });
}

class _ExploreAgent {
  final String startUrl;
  final int maxSteps;
  final int maxActionsPerStep;
  final String reportPath;
  final int cdpPort;
  final bool headless;
  final AiClient? ai;

  late CdpDriver _cdp;
  final List<_StepRecord> _steps = [];
  final Set<String> _visitedUrls = {};
  final Set<String> _testedForms = {};
  final Set<String> _clickedButtons = {};
  int _totalTokens = 0;

  _ExploreAgent({
    required this.startUrl,
    required this.maxSteps,
    required this.maxActionsPerStep,
    required this.reportPath,
    required this.cdpPort,
    required this.headless,
    this.ai,
  });

  Future<void> run() async {
    print('📡 Launching Chrome and connecting via CDP...');
    _cdp = CdpDriver(
      url: startUrl,
      port: cdpPort,
      launchChrome: cdpPort == 0,
      headless: headless,
    );
    await _cdp.connect();
    print('✅ Connected');

    await _setupConsoleMonitoring();

    // Enable CDP domains
    try {
      await _cdp.call('Performance.enable');
      await _cdp.call('Accessibility.enable');
    } catch (_) {}

    // Navigate to start URL
    await _cdp.call('Page.navigate', {'url': startUrl});
    await Future.delayed(const Duration(seconds: 2));
    await _setupConsoleMonitoring(); // Re-install after navigation

    for (int step = 0; step < maxSteps; step++) {
      print('');
      print('━━━ Step ${step + 1}/$maxSteps ━━━');

      // 1. Summarize current page
      final summary = await _summarizePage();
      print(
          '📄 ${summary.title.isEmpty ? summary.url : summary.title} (${summary.elementCount} elements)');
      if (summary.navItems.isNotEmpty) {
        print('   🧭 Nav: ${summary.navItems.take(8).join(', ')}');
      }
      if (summary.forms.isNotEmpty) {
        print(
            '   📝 Forms: ${summary.forms.length} (${summary.forms.map((f) => f.keys.join(',')).join('; ')})');
      }
      if (summary.ctaButtons.isNotEmpty) {
        print('   🎯 CTAs: ${summary.ctaButtons.join(', ')}');
      }

      // 2. Get actions from AI or rules
      final actions = ai != null
          ? await _getAiActions(summary, step)
          : _getRuleBasedActions(summary);

      if (actions.isEmpty) {
        print('   ✅ No more actions — exploration complete');
        break;
      }

      print('   🎯 ${actions.length} actions planned');

      // 3. Execute actions and record results
      final results = <String>[];
      final bugs = <String>[];
      final a11yIssues = <String>[];

      // Run a11y audit once per unique URL
      final currentUrl = await _getCurrentUrl();
      if (!_visitedUrls.contains(_normalizeUrl(currentUrl))) {
        _visitedUrls.add(_normalizeUrl(currentUrl));
        final a11y = await _cdp.accessibilityAudit();
        final issues = (a11y['issues'] as List?) ?? [];
        a11yIssues.addAll(
            issues.map((i) => '${i['type']}: [${i['rule']}] ${i['message']}'));
        if (a11yIssues.isNotEmpty) {
          print('   ♿ ${a11yIssues.length} accessibility issues');
        }
      }

      for (final action in actions) {
        final result = await _executeAction(action);
        results.add(result);
        if (result.startsWith('BUG:')) bugs.add(result.substring(4).trim());
        print('   ${result.startsWith('BUG:') ? '🐛' : '✓'} $result');
      }

      // Collect console errors
      final errors = await _collectErrors();
      if (errors.isNotEmpty) {
        bugs.addAll(errors.map((e) => 'Console: $e'));
        print('   ⚠️ ${errors.length} console errors');
      }

      // Take screenshot
      final screenshot = await _cdp.takeScreenshot(quality: 0.8);

      _steps.add(_StepRecord(
        step: step,
        url: currentUrl,
        summary: summary,
        actions: actions,
        results: results,
        bugs: bugs,
        a11yIssues: a11yIssues,
      )..screenshotBase64 = screenshot);
    }

    await _cdp.disconnect();

    // Generate report
    print('');
    print('📊 Generating report...');
    await _generateReport();

    final totalBugs = _steps.fold<int>(0, (s, r) => s + r.bugs.length);
    final totalA11y = _steps.fold<int>(0, (s, r) => s + r.a11yIssues.length);
    print('');
    print('═══════════════════════════════════════════════');
    print('  📋 Exploration Complete');
    print('  Steps: ${_steps.length}');
    print('  Pages visited: ${_visitedUrls.length}');
    print('  Bugs found: $totalBugs');
    print('  Accessibility issues: $totalA11y');
    if (ai != null) print('  Tokens used: $_totalTokens');
    print('  Report: $reportPath');
    print('═══════════════════════════════════════════════');
  }

  // ─── Page Summary ─────────────────────────────────────────────────

  Future<_PageSummary> _summarizePage() async {
    // Wait for page to be stable (SPA rendering, lazy loading)
    await _waitForPageStable();

    final currentUrl = await _getCurrentUrl();
    final title = await _getPageTitle();

    // Use CDP Accessibility tree for semantic page understanding
    final axTree = await _getAccessibilityTree();

    // Extract structured info from AX tree
    final navItems = <String>[];
    final forms = <Map<String, String>>[];
    final ctaButtons = <String>[];
    final otherButtons = <String>[];
    final headings = <String>[];
    var linkCount = 0;
    var elementCount = 0;
    var hasSearch = false;
    var hasLogin = false;
    var hasPagination = false;
    var hasModal = false;

    final ctaPattern = RegExp(
        r'sign.?up|get.?start|try|buy|add.?to|subscribe|download|register|create|join',
        caseSensitive: false);

    Map<String, String>? currentForm;
    var insideNavigation = false;
    var insideNavDepth = 0;

    for (final node in axTree) {
      final role = node['role'] as String? ?? '';
      final name = node['name'] as String? ?? '';
      final depth = node['depth'] as int? ?? 0;

      // Track if we're inside a navigation landmark
      if (role == 'navigation' || role == 'menubar' || role == 'menu') {
        insideNavigation = true;
        insideNavDepth = depth;
      } else if (insideNavigation && depth <= insideNavDepth) {
        insideNavigation = false;
      }

      if (name.isEmpty && role != 'textbox' && role != 'searchbox') continue;

      switch (role) {
        case 'navigation':
        case 'menubar':
        case 'menu':
          break;
        case 'link':
          linkCount++;
          elementCount++;
          // Only treat as nav item if inside navigation landmark or depth <= 2
          // Filter out product/content links (contain prices, are too long, etc.)
          if ((insideNavigation || depth <= 2) &&
              name.length > 1 &&
              name.length < 40 &&
              !RegExp(r'[\$€£¥]\d|CO₂|^\d+\s*(hours?|minutes?|days?)\s*ago')
                  .hasMatch(name)) {
            navItems.add(name);
          }
          break;
        case 'button':
        case 'menuitem':
          elementCount++;
          if (name.isNotEmpty) {
            final ref = 'button:$name';
            if (ctaPattern.hasMatch(name)) {
              ctaButtons.add(ref);
            } else {
              otherButtons.add(ref);
            }
          }
          break;
        case 'textbox':
        case 'searchbox':
        case 'spinbutton':
        case 'combobox':
          elementCount++;
          final nameLower = name.toLowerCase();
          hasSearch = hasSearch ||
              role == 'searchbox' ||
              nameLower.contains('search') ||
              nameLower.contains('query');
          hasLogin = hasLogin || nameLower.contains('password');
          final ref =
              name.isNotEmpty ? 'input:$name' : 'input:${role}_$elementCount';
          final inputType = role == 'searchbox'
              ? 'search'
              : (nameLower.contains('password')
                  ? 'password'
                  : (nameLower.contains('email')
                      ? 'email'
                      : (nameLower.contains('url')
                          ? 'url'
                          : (role == 'spinbutton' ? 'number' : 'text'))));
          currentForm ??= {};
          currentForm[ref] = inputType;
          break;
        case 'heading':
          if (headings.length < 5 && name.isNotEmpty) {
            headings.add(name.length > 60 ? name.substring(0, 60) : name);
          }
          break;
        case 'dialog':
          hasModal = true;
          break;
        case 'checkbox':
        case 'radio':
        case 'slider':
        case 'switch':
        case 'tab':
          elementCount++;
          break;
      }

      // Detect pagination from names
      if (name.toLowerCase().contains('pagination') ||
          name.toLowerCase().contains('next page') ||
          name.toLowerCase().contains('previous page')) {
        hasPagination = true;
      }
    }

    // Finalize current form if any
    if (currentForm != null && currentForm.isNotEmpty) {
      forms.add(currentForm);
    }

    // Also check for login via password fields using a focused CDP query
    if (!hasLogin) {
      final pwCheck = await _cdp
          .evaluate('document.querySelector("input[type=password]") !== null');
      hasLogin = pwCheck['result']?['value'] == true;
    }

    // Also get top-of-page links via JS (AX tree may miss non-semantic navbars)
    try {
      final topLinksResult = await _cdp.evaluate(r'''
        JSON.stringify(
          Array.from(document.querySelectorAll('a[href]'))
            .filter(a => { const r = a.getBoundingClientRect(); return r.top >= 0 && r.top < 120 && r.height > 0 && r.height < 60; })
            .map(a => (a.textContent || '').trim())
            .filter(t => t && t.length > 0 && t.length < 50)
            .slice(0, 15)
        )
      ''');
      final v = topLinksResult['result']?['value'] as String?;
      if (v != null) {
        final topLinks = (jsonDecode(v) as List).cast<String>();
        // Prepend top links so they're explored first
        navItems.insertAll(0, topLinks);
      }
    } catch (_) {}

    // Deduplicate nav items (keep first 15)
    final uniqueNav = <String>[];
    final seen = <String>{};
    for (final n in navItems) {
      if (seen.add(n.toLowerCase())) uniqueNav.add(n);
      if (uniqueNav.length >= 15) break;
    }

    return _PageSummary(
      url: currentUrl,
      title: title,
      navItems: uniqueNav,
      forms: forms,
      ctaButtons: ctaButtons,
      otherButtons: otherButtons.take(10).toList(),
      linkCount: linkCount,
      elementCount: elementCount,
      hasPagination: hasPagination,
      hasSearch: hasSearch,
      hasLogin: hasLogin,
      hasModal: hasModal,
      headings: headings,
      consoleErrors: await _collectErrors(),
    );
  }

  /// Get the accessibility tree via CDP — compact semantic representation
  Future<List<Map<String, dynamic>>> _getAccessibilityTree() async {
    try {
      final result = await _cdp.call('Accessibility.getFullAXTree', {
        'depth': 8,
      });
      final nodes = (result['nodes'] as List?) ?? [];

      final parsed = <Map<String, dynamic>>[];
      // Build a depth map from parent relationships
      final depthMap = <String, int>{};

      for (final node in nodes) {
        final nodeId = node['nodeId'] as String? ?? '';
        final parentId = node['parentId'] as String? ?? '';
        final role = node['role']?['value'] as String? ?? '';
        final ignored = node['ignored'] as bool? ?? false;

        if (ignored) continue;
        if (role == 'none' ||
            role == 'generic' ||
            role == 'InlineTextBox' ||
            role == 'StaticText' ||
            role == 'paragraph' ||
            role == 'group' ||
            role == 'Section' ||
            role == 'list' ||
            role == 'listitem' ||
            role == 'LineBreak') continue;

        final depth =
            depthMap.containsKey(parentId) ? depthMap[parentId]! + 1 : 0;
        depthMap[nodeId] = depth;

        // Extract name from properties
        String name = '';
        String value = '';
        bool focusable = false;

        final nameObj = node['name'];
        if (nameObj is Map) {
          name = (nameObj['value'] as String? ?? '').trim();
        }
        final valueObj = node['value'];
        if (valueObj is Map) {
          value = (valueObj['value'] as String? ?? '').trim();
        }

        final properties = (node['properties'] as List?) ?? [];
        for (final prop in properties) {
          if (prop['name'] == 'focusable') {
            focusable = prop['value']?['value'] == true;
          }
        }

        parsed.add({
          'role': role,
          'name': name,
          'value': value,
          'focusable': focusable,
          'depth': depth,
        });
      }

      return parsed;
    } catch (e) {
      // Fallback: use JS-based element discovery
      return _getElementsFallback();
    }
  }

  /// Fallback element discovery via JS (when AX tree is unavailable)
  Future<List<Map<String, dynamic>>> _getElementsFallback() async {
    final result = await _cdp.evaluate(r'''
      JSON.stringify((() => {
        const els = [];
        document.querySelectorAll('a, button, input, select, textarea, [role], h1, h2, h3').forEach(el => {
          const s = getComputedStyle(el);
          if (s.display === 'none' || s.visibility === 'hidden') return;
          const role = el.getAttribute('role') || el.tagName.toLowerCase();
          const name = (el.getAttribute('aria-label') || el.textContent || '').trim().substring(0, 80);
          els.push({ role: role === 'a' ? 'link' : (role === 'input' ? 'textbox' : role), name, value: el.value || '', focusable: true, depth: 2 });
        });
        return els;
      })())
    ''');
    final v = result['result']?['value'] as String? ?? '[]';
    return (jsonDecode(v) as List).cast<Map<String, dynamic>>();
  }

  /// Wait for page to be stable using CDP lifecycle events
  Future<void> _waitForPageStable() async {
    // Use Performance.getMetrics to check if page is done loading
    try {
      // First wait a baseline amount
      await Future.delayed(const Duration(milliseconds: 300));

      // Check document readyState
      for (int i = 0; i < 10; i++) {
        final state = await _cdp.evaluate('document.readyState');
        final readyState = state['result']?['value'] as String? ?? '';
        if (readyState == 'complete') break;
        await Future.delayed(const Duration(milliseconds: 300));
      }

      // Wait for network idle (no pending requests for 500ms)
      // Check via Performance timing
      final metrics = await _cdp.call('Performance.getMetrics');
      final metricsList = (metrics['metrics'] as List?) ?? [];
      for (final m in metricsList) {
        if (m['name'] == 'TaskDuration') {
          // Page has been processing tasks
          break;
        }
      }

      // Extra wait for SPA frameworks (React, Vue, Angular hydration)
      await Future.delayed(const Duration(milliseconds: 500));
    } catch (_) {
      // Fallback: just wait
      await Future.delayed(const Duration(seconds: 1));
    }
  }

  /// Get navigation history to track SPA navigations
  // ─── AI Actions ───────────────────────────────────────────────────

  Future<List<_ExploreAction>> _getAiActions(
      _PageSummary summary, int step) async {
    final history = _steps
        .map((s) =>
            'Step ${s.step + 1}: ${s.url} → ${s.actions.map((a) => a.toString()).join(', ')} → ${s.results.join(', ')}')
        .join('\n');

    final prompt =
        '''You are a QA tester exploring a web app. Decide the next actions to test.

Page summary:
${summary.toString()}

${history.isNotEmpty ? 'History:\n$history\n' : ''}
Already tested forms: ${_testedForms.join(', ')}
Already clicked: ${_clickedButtons.join(', ')}

Return a JSON array of $maxActionsPerStep actions. Each action:
{"type":"tap|fill|scroll|navigate|back|boundary_test","target":"ref_string","value":"for_fill","reason":"brief_why"}

Rules:
- Prioritize: untested nav items > forms > CTA buttons > interactive elements
- For forms: fill with realistic test data, then submit
- For boundary_test: fill with edge cases (empty, XSS, SQL injection, very long text)
- Don't repeat already-tested elements
- Use "back" to return after testing a sub-page
- Use "scroll" with target "down" or "up"
- Test core user flows (search, login, main features)
- Skip: logout, delete, external links, social sharing buttons

Return ONLY the JSON array, no other text.''';

    try {
      final response = await ai!.complete(prompt, maxTokens: 500);
      _totalTokens += response.tokensUsed;

      // Parse JSON array from response
      final text = response.text.trim();
      final jsonStart = text.indexOf('[');
      final jsonEnd = text.lastIndexOf(']');
      if (jsonStart >= 0 && jsonEnd > jsonStart) {
        final jsonStr = text.substring(jsonStart, jsonEnd + 1);
        final list = jsonDecode(jsonStr) as List;
        return list
            .map((j) => _ExploreAction.fromJson(j as Map<String, dynamic>))
            .toList();
      }
    } catch (e) {
      print('   ⚠️ AI error, falling back to rules: $e');
    }

    return _getRuleBasedActions(summary);
  }

  // ─── Rule-Based Fallback ──────────────────────────────────────────

  List<_ExploreAction> _getRuleBasedActions(_PageSummary summary) {
    final actions = <_ExploreAction>[];

    // 1. Dismiss modal if present
    if (summary.hasModal) {
      actions.add(_ExploreAction(
        type: 'tap',
        target: 'button:Close',
        reason: 'dismiss modal',
      ));
    }

    // 2. Fill search if available and untested
    if (summary.hasSearch && !_testedForms.contains('${summary.url}|search')) {
      actions.add(_ExploreAction(
        type: 'fill',
        target: 'input:search',
        value: 'test query',
        reason: 'test search functionality',
      ));
      actions.add(_ExploreAction(
        type: 'tap',
        target: 'button:Search',
        reason: 'submit search',
      ));
      _testedForms.add('${summary.url}|search');
    }

    // 3. Fill forms with test data + boundary tests
    for (final form in summary.forms) {
      final formKey = '${summary.url}|${form.keys.join(',')}';
      if (_testedForms.contains(formKey)) continue;
      _testedForms.add(formKey);

      for (final entry in form.entries) {
        final ref = entry.key;
        final type = entry.value;

        String testValue;
        if (type == 'email') {
          testValue = 'test@example.com';
        } else if (type == 'password') {
          testValue = 'TestPass123!';
        } else if (type == 'number' || type == 'tel') {
          testValue = '12345';
        } else if (type == 'url') {
          testValue = 'https://example.com';
        } else {
          testValue = 'Test input value';
        }

        actions.add(_ExploreAction(
          type: 'fill',
          target: ref,
          value: testValue,
          reason: 'fill form field',
        ));
      }

      // Boundary test on first text field
      final textField = form.entries
          .where(
              (e) => e.value == 'text' || e.value == 'email' || e.value == '')
          .firstOrNull;
      if (textField != null) {
        actions.add(_ExploreAction(
          type: 'boundary_test',
          target: textField.key,
          reason: 'test input boundaries',
        ));
      }

      break; // One form per step
    }

    // 4. Click untested nav items (up to 3)
    for (final nav in summary.navItems.take(6)) {
      final ref = 'link:$nav';
      if (_clickedButtons.contains(ref)) continue;
      actions.add(_ExploreAction(
        type: 'tap',
        target: ref,
        reason: 'explore navigation: $nav',
      ));
      if (actions.length >= maxActionsPerStep) break;
    }

    // 5. Click CTA buttons
    if (actions.length < maxActionsPerStep) {
      for (final cta in summary.ctaButtons) {
        if (_clickedButtons.contains(cta)) continue;
        final text = cta.replaceFirst('button:', '').toLowerCase();
        // Skip dangerous CTAs
        if (text.contains('delete') ||
            text.contains('remove') ||
            text.contains('logout')) continue;
        actions.add(_ExploreAction(
          type: 'tap',
          target: cta,
          reason: 'test CTA button',
        ));
        if (actions.length >= maxActionsPerStep) break;
      }
    }

    // 6. Click other buttons (non-CTA)
    if (actions.length < maxActionsPerStep) {
      for (final btn in summary.otherButtons) {
        if (_clickedButtons.contains(btn)) continue;
        final text = btn.replaceFirst('button:', '').toLowerCase();
        if (text.contains('delete') ||
            text.contains('remove') ||
            text.contains('logout') ||
            text.contains('sign out') ||
            text.contains('close')) continue;
        actions.add(_ExploreAction(
          type: 'tap',
          target: btn,
          reason: 'test button',
        ));
        if (actions.length >= maxActionsPerStep) break;
      }
    }

    // 7. Scroll down once (track if we've scrolled)
    if (actions.length < maxActionsPerStep &&
        !_clickedButtons.contains('__scrolled_${_normalizeUrl(summary.url)}')) {
      _clickedButtons.add('__scrolled_${_normalizeUrl(summary.url)}');
      actions.add(_ExploreAction(
        type: 'scroll',
        target: 'down',
        reason: 'discover below-fold content',
      ));
    }

    // 8. If nothing left to do, navigate back or stop
    if (actions.isEmpty && _visitedUrls.length > 1) {
      actions.add(_ExploreAction(
        type: 'back',
        target: '',
        reason: 'return to previous page',
      ));
    }

    return actions.take(maxActionsPerStep).toList();
  }

  // ─── Action Execution ─────────────────────────────────────────────

  Future<String> _executeAction(_ExploreAction action) async {
    _clickedButtons.add(action.target);

    try {
      switch (action.type) {
        case 'tap':
          final beforeUrl = await _getCurrentUrl();
          final beforeTitle = await _getPageTitle();
          await _cdp.tap(ref: action.target);
          // Wait for SPA routing and DOM updates
          await Future.delayed(const Duration(milliseconds: 500));
          // Check for URL or content change (hash routing, SPA)
          var afterUrl = await _getCurrentUrl();
          var afterTitle = await _getPageTitle();
          // If no change yet, wait longer for SPA frameworks
          if (afterUrl == beforeUrl && afterTitle == beforeTitle) {
            await Future.delayed(const Duration(milliseconds: 1000));
            afterUrl = await _getCurrentUrl();
            afterTitle = await _getPageTitle();
          }
          final changed = beforeUrl != afterUrl || beforeTitle != afterTitle;
          if (changed) {
            await _setupConsoleMonitoring();
            _visitedUrls.add(_normalizeUrl(afterUrl));
          }
          return 'Tapped ${action.target}${action.reason != null ? ' (${action.reason})' : ''}${changed ? ' → $afterUrl' : ''}';

        case 'fill':
          final value = action.value ?? 'test';
          await _smartFill(action.target, value);
          return 'Filled ${action.target} with "$value"';

        case 'boundary_test':
          return await _runBoundaryTest(action.target);

        case 'scroll':
          final direction = action.target == 'up' ? -500 : 500;
          await _cdp.evaluate(
              'window.scrollBy({top: $direction, behavior: "smooth"})');
          await Future.delayed(const Duration(milliseconds: 300));
          return 'Scrolled ${action.target}';

        case 'navigate':
          await _cdp.call('Page.navigate', {'url': action.target});
          await Future.delayed(const Duration(seconds: 2));
          await _setupConsoleMonitoring();
          return 'Navigated to ${action.target}';

        case 'back':
          await _cdp.evaluate('window.history.back()');
          await Future.delayed(const Duration(seconds: 1));
          return 'Navigated back';

        default:
          return 'Unknown action: ${action.type}';
      }
    } catch (e) {
      final errorStr = e.toString();
      // Element not found is common, not a bug
      if (errorStr.contains('not found') || errorStr.contains('No element')) {
        return 'Skipped ${action.target} (element not found)';
      }
      return 'BUG: Action ${action.type} on ${action.target} failed: $errorStr';
    }
  }

  /// Fill an input, trying multiple strategies
  Future<void> _smartFill(String ref, String value) async {
    try {
      // Try by ref first
      await _cdp.fill(ref, value);
    } catch (_) {
      // Try extracting selector from ref
      final name = ref.replaceFirst(RegExp(r'^input:'), '');
      try {
        await _cdp.evaluate('''
          (() => {
            const el = document.querySelector('[name="$name"]') 
              || document.querySelector('[placeholder*="$name"]')
              || document.querySelector('[aria-label*="$name"]')
              || document.querySelector('#$name');
            if (el) { el.value = ${jsonEncode(value)}; el.dispatchEvent(new Event('input', {bubbles:true})); }
          })()
        ''');
      } catch (_) {
        // Give up silently
      }
    }
  }

  /// Boundary testing: XSS, long strings, special chars
  Future<String> _runBoundaryTest(String target) async {
    final testCases = <String, String>{
      'empty': '',
      'xss': '<script>alert("xss")</script>',
      'sql': "'; DROP TABLE users; --",
      'long': 'a' * 300,
      'emoji': '🎉🔥💀🦀',
      'html': '"><img src=x onerror=alert(1)>',
    };

    final bugs = <String>[];

    for (final entry in testCases.entries) {
      try {
        await _smartFill(target, entry.value);
        await Future.delayed(const Duration(milliseconds: 200));
        final errors = await _collectErrors();
        if (errors.isNotEmpty) {
          bugs.add('${entry.key}: ${errors.join(', ')}');
        }

        // Check for XSS reflection
        if (entry.key == 'xss' || entry.key == 'html') {
          final reflected = await _cdp.evaluate('''
            document.documentElement.innerHTML.includes('onerror=alert') || 
            document.querySelectorAll('script').length > document.querySelectorAll('script[src]').length + 1
          ''');
          if (reflected['result']?['value'] == true) {
            bugs.add('POTENTIAL XSS: ${entry.key} payload reflected in DOM');
          }
        }
      } catch (_) {}
    }

    if (bugs.isNotEmpty) {
      return 'BUG: Boundary test on $target: ${bugs.join('; ')}';
    }
    return 'Boundary test on $target: all passed';
  }

  // ─── Utilities ────────────────────────────────────────────────────

  Future<void> _setupConsoleMonitoring() async {
    await _cdp.call('Runtime.enable');
    await _cdp.call('Log.enable');
    await _cdp.evaluate('''
      window.__fs_explore_errors__ = window.__fs_explore_errors__ || [];
      window.addEventListener('error', (e) => {
        window.__fs_explore_errors__.push({
          type: 'error',
          message: e.message || String(e),
          source: e.filename || '',
          line: e.lineno || 0
        });
      });
      window.addEventListener('unhandledrejection', (e) => {
        window.__fs_explore_errors__.push({
          type: 'unhandledrejection',
          message: e.reason?.message || String(e.reason),
          source: '',
          line: 0
        });
      });
    ''');
  }

  Future<List<String>> _collectErrors() async {
    final result = await _cdp.evaluate('''
      JSON.stringify(window.__fs_explore_errors__ || [])
    ''');
    final v = result['result']?['value'] as String?;
    if (v == null) return [];
    final list = jsonDecode(v) as List;
    await _cdp.evaluate('window.__fs_explore_errors__ = []');
    return list.map((e) => '${e['type']}: ${e['message']}').toList();
  }

  Future<String> _getPageTitle() async {
    final result = await _cdp.evaluate('document.title');
    return result['result']?['value'] as String? ?? '';
  }

  Future<String> _getCurrentUrl() async {
    final result = await _cdp.evaluate('window.location.href');
    return result['result']?['value'] as String? ?? startUrl;
  }

  String _normalizeUrl(String url) {
    try {
      final uri = Uri.parse(url);
      var normalized = uri.replace(fragment: '').toString();
      normalized = normalized.replaceAll(RegExp(r'#$'), '');
      normalized = normalized.replaceAll(RegExp(r'/$'), '');
      return normalized;
    } catch (_) {
      return url;
    }
  }

  // ─── Report Generation ────────────────────────────────────────────

  Future<void> _generateReport() async {
    final buffer = StringBuffer();
    buffer.writeln('<!DOCTYPE html>');
    buffer.writeln('<html lang="en"><head>');
    buffer.writeln('<meta charset="utf-8">');
    buffer.writeln(
        '<meta name="viewport" content="width=device-width, initial-scale=1">');
    buffer.writeln('<title>flutter-skill explore Report</title>');
    buffer.writeln('<style>');
    buffer.writeln('''
      * { box-sizing: border-box; margin: 0; padding: 0; }
      body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: #0f172a; color: #e2e8f0; padding: 2rem; }
      h1 { font-size: 2rem; margin-bottom: 0.5rem; }
      .summary { display: flex; gap: 1rem; margin: 1.5rem 0; flex-wrap: wrap; }
      .stat { background: #1e293b; border-radius: 12px; padding: 1rem 1.5rem; min-width: 140px; }
      .stat-value { font-size: 2rem; font-weight: bold; }
      .stat-label { font-size: 0.85rem; color: #94a3b8; }
      .stat-value.errors { color: #f87171; }
      .stat-value.warnings { color: #fbbf24; }
      .stat-value.ok { color: #4ade80; }
      .step { background: #1e293b; border-radius: 12px; padding: 1.5rem; margin: 1rem 0; }
      .step-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 0.5rem; }
      .step-num { font-size: 1.2rem; font-weight: bold; color: #60a5fa; }
      .step-url { font-size: 0.85rem; color: #94a3b8; word-break: break-all; }
      .action-list { margin: 0.75rem 0; }
      .action { padding: 0.3rem 0; font-size: 0.9rem; font-family: monospace; }
      .action .result { color: #94a3b8; }
      .bug { background: #7f1d1d33; border-left: 3px solid #f87171; padding: 0.5rem 0.75rem; margin: 0.3rem 0; border-radius: 4px; font-size: 0.9rem; }
      .a11y-issue { background: #78350f33; border-left: 3px solid #fbbf24; padding: 0.5rem 0.75rem; margin: 0.3rem 0; border-radius: 4px; font-size: 0.9rem; }
      .screenshot { max-width: 100%; max-height: 300px; border-radius: 8px; margin-top: 0.75rem; border: 1px solid #334155; cursor: pointer; }
      .screenshot:hover { border-color: #60a5fa; }
      .section-title { font-size: 1.3rem; margin: 2rem 0 0.5rem; padding-bottom: 0.5rem; border-bottom: 1px solid #334155; }
      .token-badge { background: #1e40af; color: #93c5fd; padding: 0.2rem 0.6rem; border-radius: 999px; font-size: 0.75rem; }
    ''');
    buffer.writeln('</style></head><body>');

    final totalBugs = _steps.fold<int>(0, (s, r) => s + r.bugs.length);
    final totalA11y = _steps.fold<int>(0, (s, r) => s + r.a11yIssues.length);

    buffer.writeln('<h1>🤖 flutter-skill explore Report</h1>');
    buffer.writeln(
        '<p style="color:#94a3b8">Generated ${DateTime.now().toIso8601String()} — Start URL: $startUrl</p>');

    buffer.writeln('<div class="summary">');
    buffer.writeln(
        '<div class="stat"><div class="stat-value">${_steps.length}</div><div class="stat-label">Steps</div></div>');
    buffer.writeln(
        '<div class="stat"><div class="stat-value">${_visitedUrls.length}</div><div class="stat-label">Pages</div></div>');
    buffer.writeln(
        '<div class="stat"><div class="stat-value errors">$totalBugs</div><div class="stat-label">Bugs</div></div>');
    buffer.writeln(
        '<div class="stat"><div class="stat-value warnings">$totalA11y</div><div class="stat-label">A11y Issues</div></div>');
    if (ai != null) {
      buffer.writeln(
          '<div class="stat"><div class="stat-value">$_totalTokens</div><div class="stat-label">Tokens Used</div></div>');
    }
    buffer.writeln('</div>');

    buffer.writeln('<h2 class="section-title">Exploration Steps</h2>');

    for (final step in _steps) {
      buffer.writeln('<div class="step">');
      buffer.writeln('<div class="step-header">');
      buffer.writeln('<span class="step-num">Step ${step.step + 1}</span>');
      buffer.writeln('<span class="step-url">${_htmlEscape(step.url)}</span>');
      buffer.writeln('</div>');

      buffer.writeln('<div class="action-list">');
      for (int i = 0; i < step.actions.length; i++) {
        final action = step.actions[i];
        final result = i < step.results.length ? step.results[i] : '';
        buffer.writeln(
            '<div class="action">→ ${_htmlEscape(action.toString())} <span class="result">→ ${_htmlEscape(result)}</span></div>');
      }
      buffer.writeln('</div>');

      if (step.bugs.isNotEmpty) {
        for (final bug in step.bugs) {
          buffer.writeln('<div class="bug">🐛 ${_htmlEscape(bug)}</div>');
        }
      }

      if (step.a11yIssues.isNotEmpty) {
        for (final issue in step.a11yIssues) {
          buffer
              .writeln('<div class="a11y-issue">♿ ${_htmlEscape(issue)}</div>');
        }
      }

      if (step.screenshotBase64 != null) {
        buffer.writeln(
            '<img class="screenshot" src="data:image/jpeg;base64,${step.screenshotBase64}" alt="Step ${step.step + 1}">');
      }

      buffer.writeln('</div>');
    }

    buffer.writeln('</body></html>');

    final file = File(reportPath);
    await file.writeAsString(buffer.toString());
    print('   ✅ Report saved to $reportPath');
  }

  String _htmlEscape(String text) {
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;');
  }
}
