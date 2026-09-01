import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../bridge/cdp_driver.dart';

/// `flutter-skill security` — Security Scanner for web apps.
///
/// Usage:
///   flutter-skill security https://my-app.com [--report=security-report.html] [--depth=2]
Future<void> runSecurity(List<String> args) async {
  String? url;
  int depth = 2;
  String reportPath = 'security-report.html';
  int cdpPort = 0; // 0 = auto-assign random port
  bool headless = true;
  int maxPages = 10;
  int maxLinks = 20;

  for (final arg in args) {
    if (arg.startsWith('--depth=')) {
      depth = int.parse(arg.substring(8));
    } else if (arg.startsWith('--report=')) {
      reportPath = arg.substring(9);
    } else if (arg.startsWith('--cdp-port=')) {
      cdpPort = int.parse(arg.substring(11));
    } else if (arg == '--no-headless') {
      headless = false;
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
        'Usage: flutter-skill security <url> [--report=security-report.html] [--depth=2]');
    print('');
    print('Options:');
    print('  --depth=N          Max crawl depth (default: 2)');
    print(
        '  --report=PATH      HTML report output path (default: security-report.html)');
    print('  --cdp-port=N       Chrome DevTools port (default: 9222)');
    print('  --no-headless      Run Chrome with UI visible');
    print('  --max-pages=N      Max pages to scan (default: 10)');
    print('  --max-links=N      Max links to follow per page (default: 20)');
    exit(1);
  }

  print('🔒 flutter-skill security — Security Scanner');
  print('');
  print('   URL: $url');
  print('   Depth: $depth');
  print('   Report: $reportPath');
  print('');

  final scanner = SecurityScanner(
    startUrl: url,
    maxDepth: depth,
    cdpPort: cdpPort,
    headless: headless,
    reportPath: reportPath,
    maxPages: maxPages,
    maxLinks: maxLinks,
  );

  final findings = await scanner.run();

  // Summary
  final critical = findings.where((f) => f.severity == 'Critical').length;
  final high = findings.where((f) => f.severity == 'High').length;
  final medium = findings.where((f) => f.severity == 'Medium').length;
  final low = findings.where((f) => f.severity == 'Low').length;
  final info = findings.where((f) => f.severity == 'Info').length;

  print('');
  print('═══════════════════════════════════════════════');
  print('  🔒 Security Scan Complete');
  print('  Total findings: ${findings.length}');
  if (critical > 0) print('  🔴 Critical: $critical');
  if (high > 0) print('  🟠 High: $high');
  if (medium > 0) print('  🟡 Medium: $medium');
  if (low > 0) print('  🔵 Low: $low');
  if (info > 0) print('  ⚪ Info: $info');
  print('  Report: $reportPath');
  print('═══════════════════════════════════════════════');
}

/// XSS test payloads
const xssPayloads = [
  '<script>alert(1)</script>',
  '<script>alert("XSS")</script>',
  '"><script>alert(1)</script>',
  "';alert(1)//",
  '<img src=x onerror=alert(1)>',
  '<img src=x onerror="alert(1)">',
  '<svg onload=alert(1)>',
  '<svg/onload=alert(1)>',
  '<body onload=alert(1)>',
  '<input onfocus=alert(1) autofocus>',
  '<marquee onstart=alert(1)>',
  '<details open ontoggle=alert(1)>',
  '<iframe src="javascript:alert(1)">',
  'javascript:alert(1)',
  'jaVaScRiPt:alert(1)',
  '"><img src=x onerror=alert(1)>',
  "'-alert(1)-'",
  '<div style="width:expression(alert(1))">',
  '{{constructor.constructor("alert(1)")()}}',
  '\${alert(1)}',
  '<a href="javascript:alert(1)">click</a>',
  '<math><mtext><table><mglyph><svg><mtext><textarea><path id="</textarea><img onerror=alert(1) src=1>">',
];

/// Sensitive data patterns
final sensitivePatterns = {
  'API Key (sk-)': RegExp(r'sk-[a-zA-Z0-9]{20,}'),
  'API Key (pk_)': RegExp(r'pk_[a-zA-Z0-9]{20,}'),
  'API Key (api_key)': RegExp('api_key[=:]\\s*["\']?[a-zA-Z0-9_-]{16,}'),
  'API Key (apikey)': RegExp('apikey[=:]\\s*["\']?[a-zA-Z0-9_-]{16,}'),
  'AWS Access Key': RegExp(r'AKIA[0-9A-Z]{16}'),
  'AWS Secret Key':
      RegExp('aws_secret_access_key[=:]\\s*["\']?[a-zA-Z0-9/+=]{40}'),
  'JWT Token':
      RegExp(r'eyJ[a-zA-Z0-9_-]{10,}\.[a-zA-Z0-9_-]{10,}\.[a-zA-Z0-9_-]{10,}'),
  'Credit Card (Visa)': RegExp(r'\b4[0-9]{12}(?:[0-9]{3})?\b'),
  'Credit Card (Mastercard)': RegExp(r'\b5[1-5][0-9]{14}\b'),
  'Credit Card (Amex)': RegExp(r'\b3[47][0-9]{13}\b'),
  'Password in URL': RegExp(r'[?&]password=[^&]+'),
  'Password field value': RegExp('password["\\s]*[:=]\\s*["\'][^"\']{1,}["\']'),
  'Private Key': RegExp(r'-----BEGIN\s+(RSA\s+)?PRIVATE KEY-----'),
  'Email Address':
      RegExp(r'\b[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}\b'),
  'Bearer Token': RegExp(r'Bearer\s+[a-zA-Z0-9_.=-]{20,}'),
  'GitHub Token': RegExp(r'gh[pousr]_[A-Za-z0-9_]{36,}'),
  'Google API Key': RegExp(r'AIza[0-9A-Za-z_-]{35}'),
  'Slack Token': RegExp(r'xox[baprs]-[0-9a-zA-Z]{10,}'),
};

/// Security headers to check
const expectedSecurityHeaders = {
  'Content-Security-Policy': {
    'severity': 'High',
    'description': 'Prevents XSS and data injection attacks',
  },
  'Strict-Transport-Security': {
    'severity': 'High',
    'description': 'Enforces HTTPS connections',
  },
  'X-Frame-Options': {
    'severity': 'Medium',
    'description': 'Prevents clickjacking attacks',
  },
  'X-Content-Type-Options': {
    'severity': 'Medium',
    'description': 'Prevents MIME type sniffing',
  },
  'X-XSS-Protection': {
    'severity': 'Low',
    'description': 'Legacy XSS filter (deprecated but still useful)',
  },
  'Referrer-Policy': {
    'severity': 'Low',
    'description': 'Controls referrer information sent with requests',
  },
  'Permissions-Policy': {
    'severity': 'Medium',
    'description': 'Controls browser features and APIs',
  },
};

class SecurityFinding {
  final String category;
  final String severity; // Critical, High, Medium, Low, Info
  final String title;
  final String description;
  final String? url;
  final String? evidence;
  final String? recommendation;

  SecurityFinding({
    required this.category,
    required this.severity,
    required this.title,
    required this.description,
    this.url,
    this.evidence,
    this.recommendation,
  });

  Map<String, dynamic> toJson() => {
        'category': category,
        'severity': severity,
        'title': title,
        'description': description,
        if (url != null) 'url': url,
        if (evidence != null) 'evidence': evidence,
        if (recommendation != null) 'recommendation': recommendation,
      };
}

class SecurityScanner {
  final String startUrl;
  final int maxDepth;
  final int cdpPort;
  final bool headless;
  final String reportPath;
  final int maxPages;
  final int maxLinks;

  late CdpDriver _cdp;
  final List<SecurityFinding> _findings = [];
  final Map<String, bool> _visited = {};
  final List<(String, int)> _queue = [];
  final Map<String, Map<String, String>> _responseHeaders = {};

  SecurityScanner({
    required this.startUrl,
    required this.maxDepth,
    required this.cdpPort,
    required this.headless,
    required this.reportPath,
    this.maxPages = 10,
    this.maxLinks = 20,
  });

  Future<List<SecurityFinding>> run() async {
    print('📡 Launching Chrome and connecting via CDP...');
    _cdp = CdpDriver(
      url: startUrl,
      port: cdpPort,
      launchChrome: cdpPort == 0,
      headless: headless,
    );
    await _cdp.connect();
    print('✅ Connected');

    // Enable Network domain for header checking
    await _cdp.call('Network.enable');

    // Set up dialog handler for XSS detection
    await _cdp.call('Page.enable');

    // Crawl and scan
    _queue.add((startUrl, 0));

    while (_queue.isNotEmpty) {
      if (_visited.length >= maxPages) break;

      final (pageUrl, currentDepth) = _queue.removeAt(0);
      final normalizedUrl = _normalizeUrl(pageUrl);

      if (_visited.containsKey(normalizedUrl)) continue;
      if (currentDepth > maxDepth) continue;
      _visited[normalizedUrl] = true;

      print('');
      print('🔍 [$currentDepth/$maxDepth] Scanning: $pageUrl');

      await _scanPage(pageUrl, currentDepth);
    }

    await _cdp.disconnect();

    // Generate report
    print('');
    print('📊 Generating security report...');
    await _generateHtmlReport();

    return _findings;
  }

  /// Run security scan with specific checks (for MCP tool use)
  Future<List<SecurityFinding>> runChecks({
    required CdpDriver cdp,
    List<String> checks = const [
      'xss',
      'csrf',
      'headers',
      'sensitive_data',
      'mixed_content'
    ],
    List<String>? customXssPayloads,
  }) async {
    _cdp = cdp;

    final currentUrl = (await _cdp.evaluate('window.location.href'))['result']
            ?['value'] as String? ??
        startUrl;

    if (checks.contains('headers')) {
      await _checkSecurityHeaders(currentUrl);
    }
    if (checks.contains('xss')) {
      await _xssScan(currentUrl, customPayloads: customXssPayloads);
    }
    if (checks.contains('sensitive_data')) {
      await _sensitiveDataScan(currentUrl);
    }
    if (checks.contains('mixed_content')) {
      await _mixedContentScan(currentUrl);
    }
    if (checks.contains('csrf')) {
      await _csrfCheck(currentUrl);
    }
    if (checks.contains('open_redirect')) {
      await _openRedirectCheck(currentUrl);
    }
    if (checks.contains('clickjacking')) {
      await _clickjackingCheck(currentUrl);
    }

    return _findings;
  }

  Future<void> _scanPage(String pageUrl, int currentDepth) async {
    try {
      await _cdp.call('Page.navigate', {'url': pageUrl});
      await Future.delayed(const Duration(seconds: 2));

      // Capture response headers
      await _captureHeaders(pageUrl);

      // Run all checks
      await _checkSecurityHeaders(pageUrl);
      await _xssScan(pageUrl);
      await _sensitiveDataScan(pageUrl);
      await _mixedContentScan(pageUrl);
      await _csrfCheck(pageUrl);
      await _openRedirectCheck(pageUrl);
      await _clickjackingCheck(pageUrl);

      // Discover links for crawling
      if (currentDepth < maxDepth) {
        final linksResult = await _cdp.evaluate('''
          JSON.stringify(
            Array.from(document.querySelectorAll('a[href]'))
              .map(a => a.href)
              .filter(h => h && !h.startsWith('javascript:') && !h.startsWith('mailto:'))
          )
        ''');
        final linksJson = linksResult['result']?['value'] as String?;
        if (linksJson != null) {
          final links = (jsonDecode(linksJson) as List)
              .cast<String>()
              .take(maxLinks)
              .toList();
          for (final link in links) {
            final normLink = _normalizeUrl(link);
            if (!_visited.containsKey(normLink) &&
                _isSameOrigin(link, startUrl)) {
              _queue.add((link, currentDepth + 1));
            }
          }
        }
      }
    } catch (e) {
      print('   ❌ Error scanning: $e');
    }
  }

  Future<void> _captureHeaders(String pageUrl) async {
    try {
      // Use JavaScript to fetch headers via a same-origin request
      final result = await _cdp.evaluate('''
        (async () => {
          try {
            const resp = await fetch(window.location.href, {method: 'HEAD', cache: 'no-cache'});
            const headers = {};
            resp.headers.forEach((v, k) => headers[k] = v);
            return JSON.stringify(headers);
          } catch(e) { return '{}'; }
        })()
      ''');
      // Handle both awaited and non-awaited results
      final val = result['result']?['value'] as String?;
      if (val != null && val != '{}') {
        _responseHeaders[pageUrl] =
            (jsonDecode(val) as Map<String, dynamic>).cast<String, String>();
      }
    } catch (_) {}
  }

  Future<void> _checkSecurityHeaders(String pageUrl) async {
    print('   🔒 Checking security headers...');

    final headers = _responseHeaders[pageUrl] ?? {};

    // If no headers captured via fetch, try evaluating meta tags
    if (headers.isEmpty) {
      try {
        final metaResult = await _cdp.evaluate('''
          JSON.stringify({
            csp: document.querySelector('meta[http-equiv="Content-Security-Policy"]')?.content || null
          })
        ''');
        final metaJson = metaResult['result']?['value'] as String?;
        if (metaJson != null) {
          final meta = jsonDecode(metaJson) as Map<String, dynamic>;
          if (meta['csp'] != null) {
            headers['content-security-policy'] = meta['csp'] as String;
          }
        }
      } catch (_) {}
    }

    // Only report truly critical missing headers (CSP and HSTS)
    const criticalHeaders = {
      'Content-Security-Policy': {
        'severity': 'High',
        'description': 'Prevents XSS and data injection attacks',
      },
      'Strict-Transport-Security': {
        'severity': 'High',
        'description': 'Enforces HTTPS connections',
      },
    };

    for (final entry in criticalHeaders.entries) {
      final headerName = entry.key;
      final config = entry.value;
      final headerLower = headerName.toLowerCase();

      final found = headers.keys.any((k) => k.toLowerCase() == headerLower);
      if (!found) {
        _findings.add(SecurityFinding(
          category: 'Security Headers',
          severity: config['severity']!,
          title: 'Missing $headerName header',
          description: config['description']!,
          url: pageUrl,
          recommendation: 'Add $headerName header to server responses.',
        ));
      }
    }
  }

  Future<void> _xssScan(String pageUrl, {List<String>? customPayloads}) async {
    print('   💉 Testing XSS vulnerabilities...');

    final payloads = customPayloads ?? xssPayloads;

    // Find input fields
    final fieldsResult = await _cdp.evaluate('''
      JSON.stringify(
        Array.from(document.querySelectorAll('input, textarea, [contenteditable]'))
          .map((el, i) => ({
            index: i,
            tag: el.tagName.toLowerCase(),
            type: el.type || 'text',
            name: el.name || '',
            id: el.id || '',
            selector: el.id ? '#' + el.id : (el.name ? '[name="' + el.name + '"]' : el.tagName.toLowerCase() + ':nth-of-type(' + (i+1) + ')')
          }))
      )
    ''');

    final fieldsJson = fieldsResult['result']?['value'] as String?;
    if (fieldsJson == null) return;

    final fields =
        (jsonDecode(fieldsJson) as List).cast<Map<String, dynamic>>();

    if (fields.isEmpty) {
      print('   📝 No input fields found');
      return;
    }

    // Install dialog handler to detect alert() execution
    bool dialogDetected = false;
    await _cdp.evaluate('''
      window.__xss_dialog_detected__ = false;
      window.__original_alert__ = window.alert;
      window.alert = function() { window.__xss_dialog_detected__ = true; };
    ''');

    for (final field in fields) {
      final selector = field['selector'] as String;
      final fieldName =
          field['name'] as String? ?? field['id'] as String? ?? selector;

      for (final payload in payloads.take(5)) {
        // Limit payloads per field
        try {
          // Clear and inject payload
          await _cdp.evaluate('''
            (() => {
              const el = document.querySelector('$selector');
              if (!el) return;
              el.value = '';
              el.value = ${jsonEncode(payload)};
              el.dispatchEvent(new Event('input', {bubbles: true}));
              el.dispatchEvent(new Event('change', {bubbles: true}));
            })()
          ''');

          await Future.delayed(const Duration(milliseconds: 200));

          // Check if dialog was triggered
          final dialogResult =
              await _cdp.evaluate('window.__xss_dialog_detected__');
          dialogDetected = dialogResult['result']?['value'] == true;

          if (dialogDetected) {
            _findings.add(SecurityFinding(
              category: 'XSS',
              severity: 'Critical',
              title: 'XSS vulnerability detected in field "$fieldName"',
              description:
                  'JavaScript execution was triggered via alert() when injecting payload into the input field.',
              url: pageUrl,
              evidence: 'Payload: $payload',
              recommendation:
                  'Sanitize and escape all user input. Use Content-Security-Policy headers.',
            ));
            // Reset
            await _cdp.evaluate('window.__xss_dialog_detected__ = false');
          }

          // Check if payload is reflected in DOM
          final reflectedResult = await _cdp.evaluate('''
            document.body.innerHTML.includes(${jsonEncode(payload)})
          ''');
          final reflected = reflectedResult['result']?['value'] == true;

          if (reflected) {
            _findings.add(SecurityFinding(
              category: 'XSS',
              severity: 'High',
              title: 'XSS payload reflected in DOM for field "$fieldName"',
              description:
                  'The injected payload was found unescaped in the page DOM, indicating potential reflected XSS.',
              url: pageUrl,
              evidence: 'Payload: $payload',
              recommendation:
                  'HTML-encode all user input before rendering in the DOM.',
            ));
          }
        } catch (_) {
          // Skip failures
        }
      }
    }

    // Restore alert
    await _cdp.evaluate('''
      if (window.__original_alert__) window.alert = window.__original_alert__;
    ''');
  }

  Future<void> _sensitiveDataScan(String pageUrl) async {
    print('   🔑 Scanning for sensitive data exposure...');

    // Check localStorage
    await _scanStorage(pageUrl, 'localStorage',
        'JSON.stringify(Object.entries(localStorage))');

    // Check sessionStorage
    await _scanStorage(pageUrl, 'sessionStorage',
        'JSON.stringify(Object.entries(sessionStorage))');

    // Check cookies
    await _scanStorage(pageUrl, 'cookies', 'JSON.stringify(document.cookie)');

    // Check page source
    try {
      final sourceResult = await _cdp
          .evaluate('document.documentElement.outerHTML.substring(0, 50000)');
      final source = sourceResult['result']?['value'] as String? ?? '';

      for (final entry in sensitivePatterns.entries) {
        final matches = entry.value.allMatches(source);
        if (matches.isNotEmpty) {
          // Skip email patterns in mailto links and common false positives
          if (entry.key == 'Email Address') continue;

          _findings.add(SecurityFinding(
            category: 'Sensitive Data',
            severity: entry.key.contains('Private Key') ||
                    entry.key.contains('Password')
                ? 'Critical'
                : entry.key.contains('API Key') ||
                        entry.key.contains('AWS') ||
                        entry.key.contains('JWT')
                    ? 'High'
                    : entry.key.contains('Credit Card')
                        ? 'Critical'
                        : 'Medium',
            title: '${entry.key} found in page source',
            description:
                'Detected ${matches.length} potential ${entry.key} pattern(s) in the page HTML source.',
            url: pageUrl,
            evidence:
                'Pattern match: ${matches.first.group(0)?.substring(0, (matches.first.group(0)?.length ?? 0).clamp(0, 40))}...',
            recommendation:
                'Remove sensitive data from client-side code. Use server-side APIs.',
          ));
        }
      }
    } catch (_) {}

    // Check console logs for sensitive data
    try {
      final consoleResult = await _cdp.evaluate('''
        JSON.stringify(window.__fs_console_log__ || [])
      ''');
      final consoleJson = consoleResult['result']?['value'] as String?;
      if (consoleJson != null) {
        final logs = consoleJson;
        for (final entry in sensitivePatterns.entries) {
          if (entry.value.hasMatch(logs)) {
            _findings.add(SecurityFinding(
              category: 'Sensitive Data',
              severity: 'Medium',
              title: '${entry.key} found in console output',
              description:
                  'Detected ${entry.key} pattern in console log output.',
              url: pageUrl,
              recommendation:
                  'Remove sensitive data from console.log statements in production.',
            ));
          }
        }
      }
    } catch (_) {}
  }

  Future<void> _scanStorage(
      String pageUrl, String storageName, String jsExpr) async {
    try {
      final result = await _cdp.evaluate(jsExpr);
      final val = result['result']?['value'] as String? ?? '';

      for (final entry in sensitivePatterns.entries) {
        if (entry.value.hasMatch(val)) {
          _findings.add(SecurityFinding(
            category: 'Sensitive Data',
            severity: entry.key.contains('Password') ||
                    entry.key.contains('Private Key')
                ? 'Critical'
                : 'High',
            title: '${entry.key} found in $storageName',
            description: 'Detected ${entry.key} pattern in $storageName.',
            url: pageUrl,
            recommendation:
                'Avoid storing sensitive data in $storageName. Use secure, HttpOnly cookies for tokens.',
          ));
        }
      }
    } catch (_) {}
  }

  Future<void> _mixedContentScan(String pageUrl) async {
    if (!pageUrl.startsWith('https://')) return;

    print('   🔀 Checking for mixed content...');

    try {
      final result = await _cdp.evaluate('''
        JSON.stringify(
          Array.from(document.querySelectorAll('img, script, link, iframe, video, audio, source, object, embed'))
            .filter(el => {
              const src = el.src || el.href || el.data || '';
              return src.startsWith('http://');
            })
            .map(el => ({
              tag: el.tagName.toLowerCase(),
              src: el.src || el.href || el.data || ''
            }))
        )
      ''');

      final val = result['result']?['value'] as String?;
      if (val == null) return;

      final mixedResources =
          (jsonDecode(val) as List).cast<Map<String, dynamic>>();

      for (final resource in mixedResources) {
        final tag = resource['tag'] as String;
        final src = resource['src'] as String;
        final isActive = tag == 'script' || tag == 'iframe';

        _findings.add(SecurityFinding(
          category: 'Mixed Content',
          severity: isActive ? 'High' : 'Medium',
          title: '${isActive ? "Active" : "Passive"} mixed content: <$tag>',
          description:
              'HTTPS page loads ${isActive ? "active" : "passive"} HTTP resource.',
          url: pageUrl,
          evidence: 'Source: $src',
          recommendation:
              'Use HTTPS for all resources. Update the URL to use https://.',
        ));
      }
    } catch (_) {}
  }

  Future<void> _csrfCheck(String pageUrl) async {
    print('   🛡️ Checking CSRF protection...');

    try {
      // Check all forms (not just POST) for CSRF tokens
      final result = await _cdp.evaluate('''
        JSON.stringify(
          Array.from(document.querySelectorAll('form'))
            .map((form, i) => ({
              index: i,
              action: form.action,
              method: (form.method || 'get').toUpperCase(),
              hasCSRFToken: !!(
                form.querySelector('input[name*="csrf"]') ||
                form.querySelector('input[name*="token"]') ||
                form.querySelector('input[name*="_token"]') ||
                form.querySelector('input[name="authenticity_token"]') ||
                document.querySelector('meta[name="csrf-token"]')
              ),
              hasInputs: form.querySelectorAll('input, textarea, select').length > 0
            }))
        )
      ''');

      final val = result['result']?['value'] as String?;
      if (val == null) return;

      final forms = (jsonDecode(val) as List).cast<Map<String, dynamic>>();

      // Only report forms that are POST and have inputs but no CSRF token
      for (final form in forms) {
        final method = form['method'] as String? ?? 'GET';
        final hasInputs = form['hasInputs'] == true;
        if (method == 'POST' && hasInputs && form['hasCSRFToken'] != true) {
          _findings.add(SecurityFinding(
            category: 'CSRF',
            severity: 'High',
            title: 'POST form without CSRF token',
            description:
                'A POST form with input fields was found without a CSRF protection token.',
            url: pageUrl,
            evidence: 'Form action: ${form['action']}',
            recommendation:
                'Add CSRF tokens to all state-changing forms. Use SameSite cookie attribute.',
          ));
        }
      }
    } catch (_) {}
  }

  Future<void> _openRedirectCheck(String pageUrl) async {
    print('   ↪️ Checking for open redirect...');

    try {
      final uri = Uri.parse(pageUrl);
      final redirectParams = [
        'redirect',
        'redirect_uri',
        'redirect_url',
        'callback',
        'next',
        'url',
        'return',
        'returnTo',
        'return_url',
        'continue',
        'dest',
        'destination',
        'go',
        'target',
        'rurl',
        'forward',
        'forward_url'
      ];

      for (final param in uri.queryParameters.keys) {
        if (redirectParams.contains(param.toLowerCase())) {
          final value = uri.queryParameters[param] ?? '';
          // Check if the redirect parameter accepts external URLs
          if (value.startsWith('http') || value.startsWith('//')) {
            _findings.add(SecurityFinding(
              category: 'Open Redirect',
              severity: 'Medium',
              title: 'Potential open redirect via "$param" parameter',
              description:
                  'URL parameter "$param" contains an external URL, which may be exploitable for open redirect attacks.',
              url: pageUrl,
              evidence: '$param=$value',
              recommendation:
                  'Validate redirect URLs against a whitelist. Only allow relative URLs or specific domains.',
            ));
          }
        }
      }

      // Also check for redirect params in links on the page
      final linksResult = await _cdp.evaluate('''
        JSON.stringify(
          Array.from(document.querySelectorAll('a[href]'))
            .map(a => a.href)
            .filter(h => {
              const lower = h.toLowerCase();
              return lower.includes('redirect=') || lower.includes('next=') ||
                     lower.includes('url=') || lower.includes('callback=') ||
                     lower.includes('return=');
            })
            .slice(0, 10)
        )
      ''');
      final linksJson = linksResult['result']?['value'] as String?;
      if (linksJson != null) {
        final links = (jsonDecode(linksJson) as List).cast<String>();
        for (final link in links) {
          final linkUri = Uri.tryParse(link);
          if (linkUri == null) continue;
          for (final param in linkUri.queryParameters.keys) {
            if (redirectParams.contains(param.toLowerCase())) {
              final value = linkUri.queryParameters[param] ?? '';
              if (value.startsWith('http') || value.startsWith('//')) {
                _findings.add(SecurityFinding(
                  category: 'Open Redirect',
                  severity: 'Medium',
                  title: 'Link with potential open redirect via "$param"',
                  description:
                      'Found a link containing a redirect parameter with an external URL.',
                  url: pageUrl,
                  evidence:
                      link.length > 100 ? '${link.substring(0, 100)}...' : link,
                  recommendation: 'Validate redirect URLs server-side.',
                ));
              }
            }
          }
        }
      }
    } catch (_) {}
  }

  Future<void> _clickjackingCheck(String pageUrl) async {
    print('   🖼️ Checking clickjacking protection...');

    final headers = _responseHeaders[pageUrl] ?? {};

    final hasXFrameOptions =
        headers.keys.any((k) => k.toLowerCase() == 'x-frame-options');
    final csp = headers.entries
        .where((e) => e.key.toLowerCase() == 'content-security-policy')
        .map((e) => e.value)
        .firstOrNull;
    final hasFrameAncestors = csp != null && csp.contains('frame-ancestors');

    if (!hasXFrameOptions && !hasFrameAncestors) {
      _findings.add(SecurityFinding(
        category: 'Clickjacking',
        severity: 'Medium',
        title: 'No clickjacking protection',
        description:
            'Neither X-Frame-Options header nor CSP frame-ancestors directive was found.',
        url: pageUrl,
        recommendation:
            'Add X-Frame-Options: DENY or SAMEORIGIN header, or use CSP frame-ancestors directive.',
      ));
    }
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

  Future<void> _generateHtmlReport() async {
    final buffer = StringBuffer();
    buffer.writeln('<!DOCTYPE html>');
    buffer.writeln('<html lang="en"><head>');
    buffer.writeln('<meta charset="utf-8">');
    buffer.writeln(
        '<meta name="viewport" content="width=device-width, initial-scale=1">');
    buffer.writeln('<title>flutter-skill Security Report</title>');
    buffer.writeln('<style>');
    buffer.writeln('''
      * { box-sizing: border-box; margin: 0; padding: 0; }
      body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: #0f172a; color: #e2e8f0; padding: 2rem; }
      h1 { font-size: 2rem; margin-bottom: 0.5rem; }
      .summary { display: flex; gap: 1rem; margin: 1.5rem 0; flex-wrap: wrap; }
      .stat { background: #1e293b; border-radius: 12px; padding: 1rem 1.5rem; min-width: 120px; text-align: center; }
      .stat-value { font-size: 2rem; font-weight: bold; }
      .stat-label { font-size: 0.85rem; color: #94a3b8; }
      .critical { color: #ef4444; }
      .high { color: #f97316; }
      .medium { color: #eab308; }
      .low { color: #3b82f6; }
      .info { color: #94a3b8; }
      .finding { background: #1e293b; border-radius: 12px; padding: 1.25rem; margin: 0.75rem 0; }
      .finding-header { display: flex; align-items: center; gap: 0.75rem; margin-bottom: 0.5rem; }
      .severity-badge { padding: 0.2rem 0.6rem; border-radius: 6px; font-size: 0.75rem; font-weight: 600; text-transform: uppercase; }
      .severity-Critical { background: #7f1d1d; color: #fca5a5; }
      .severity-High { background: #7c2d12; color: #fed7aa; }
      .severity-Medium { background: #713f12; color: #fef08a; }
      .severity-Low { background: #1e3a5f; color: #93c5fd; }
      .severity-Info { background: #334155; color: #94a3b8; }
      .finding-title { font-weight: 600; font-size: 1rem; }
      .finding-category { color: #94a3b8; font-size: 0.85rem; }
      .finding-desc { margin: 0.5rem 0; font-size: 0.9rem; color: #cbd5e1; }
      .finding-evidence { background: #0f172a; padding: 0.5rem 0.75rem; border-radius: 6px; font-family: monospace; font-size: 0.8rem; margin: 0.5rem 0; color: #fbbf24; word-break: break-all; }
      .finding-rec { font-size: 0.85rem; color: #4ade80; margin-top: 0.5rem; }
      .section-title { font-size: 1.3rem; margin: 2rem 0 0.5rem; padding-bottom: 0.5rem; border-bottom: 1px solid #334155; }
      .filter-bar { margin: 1rem 0; display: flex; gap: 0.5rem; flex-wrap: wrap; }
      .filter-btn { background: #334155; border: none; color: #e2e8f0; padding: 0.4rem 0.8rem; border-radius: 6px; cursor: pointer; font-size: 0.85rem; }
      .filter-btn:hover, .filter-btn.active { background: #475569; }
    ''');
    buffer.writeln('</style></head><body>');

    final critical = _findings.where((f) => f.severity == 'Critical').length;
    final high = _findings.where((f) => f.severity == 'High').length;
    final medium = _findings.where((f) => f.severity == 'Medium').length;
    final low = _findings.where((f) => f.severity == 'Low').length;
    final info = _findings.where((f) => f.severity == 'Info').length;

    buffer.writeln('<h1>🔒 flutter-skill Security Report</h1>');
    buffer.writeln(
        '<p style="color:#94a3b8">Generated ${DateTime.now().toIso8601String()} — Target: $startUrl</p>');

    buffer.writeln('<div class="summary">');
    buffer.writeln(
        '<div class="stat"><div class="stat-value">${_findings.length}</div><div class="stat-label">Total Findings</div></div>');
    buffer.writeln(
        '<div class="stat"><div class="stat-value critical">$critical</div><div class="stat-label">Critical</div></div>');
    buffer.writeln(
        '<div class="stat"><div class="stat-value high">$high</div><div class="stat-label">High</div></div>');
    buffer.writeln(
        '<div class="stat"><div class="stat-value medium">$medium</div><div class="stat-label">Medium</div></div>');
    buffer.writeln(
        '<div class="stat"><div class="stat-value low">$low</div><div class="stat-label">Low</div></div>');
    buffer.writeln(
        '<div class="stat"><div class="stat-value info">$info</div><div class="stat-label">Info</div></div>');
    buffer.writeln('</div>');

    // Findings grouped by severity
    final severityOrder = ['Critical', 'High', 'Medium', 'Low', 'Info'];
    for (final sev in severityOrder) {
      final sevFindings = _findings.where((f) => f.severity == sev).toList();
      if (sevFindings.isEmpty) continue;

      buffer.writeln(
          '<h2 class="section-title">$sev (${sevFindings.length})</h2>');

      for (final f in sevFindings) {
        buffer.writeln('<div class="finding">');
        buffer.writeln('<div class="finding-header">');
        buffer.writeln(
            '<span class="severity-badge severity-${f.severity}">${f.severity}</span>');
        buffer.writeln(
            '<span class="finding-title">${_htmlEscape(f.title)}</span>');
        buffer.writeln(
            '<span class="finding-category">${_htmlEscape(f.category)}</span>');
        buffer.writeln('</div>');
        buffer.writeln(
            '<div class="finding-desc">${_htmlEscape(f.description)}</div>');
        if (f.url != null) {
          buffer.writeln(
              '<div class="finding-desc" style="font-size:0.8rem;color:#64748b">URL: ${_htmlEscape(f.url!)}</div>');
        }
        if (f.evidence != null) {
          buffer.writeln(
              '<div class="finding-evidence">${_htmlEscape(f.evidence!)}</div>');
        }
        if (f.recommendation != null) {
          buffer.writeln(
              '<div class="finding-rec">💡 ${_htmlEscape(f.recommendation!)}</div>');
        }
        buffer.writeln('</div>');
      }
    }

    if (_findings.isEmpty) {
      buffer.writeln('<div class="finding">');
      buffer.writeln(
          '<p style="color:#4ade80;font-size:1.1rem">✅ No security issues found!</p>');
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
