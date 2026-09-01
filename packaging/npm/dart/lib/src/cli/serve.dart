import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../bridge/cdp_driver.dart';

/// `flutter-skill serve` — Zero-config WebMCP server.
///
/// Connects to any running app/website via CDP and exposes
/// all interactive UI elements as MCP tools. Supports hot reload
/// detection — when the page changes, tools auto-update.
///
/// Usage:
///   flutter-skill serve --url=https://example.com
///   flutter-skill serve --cdp-port=9222 --no-launch
///   flutter-skill serve --url=https://example.com --port=3000 --headless
Future<void> runServe(List<String> args) async {
  String url = 'about:blank';
  int cdpPort = 9222;
  int serverPort = 3000;
  bool headless = false;
  bool launchChrome = true;
  bool watch = true;

  for (final arg in args) {
    if (arg.startsWith('--url=')) {
      url = arg.substring(6);
    } else if (arg.startsWith('--cdp-port=')) {
      cdpPort = int.parse(arg.substring(11));
    } else if (arg.startsWith('--chrome-port=')) {
      // Support --chrome-port as an alias for --cdp-port
      cdpPort = int.parse(arg.substring(14));
    } else if (arg.startsWith('--port=')) {
      serverPort = int.parse(arg.substring(7));
    } else if (arg == '--headless') {
      headless = true;
    } else if (arg == '--no-launch') {
      launchChrome = false;
    } else if (arg == '--no-watch') {
      watch = false;
    } else if (!arg.startsWith('-')) {
      // Positional arg = URL
      url = arg;
    }
  }

  if (url == 'about:blank' && launchChrome) {
    print('Usage: flutter-skill serve <url>');
    print('');
    print('Examples:');
    print('  flutter-skill serve https://example.com');
    print('  flutter-skill serve https://amazon.com --port=3000');
    print('  flutter-skill serve --cdp-port=9222 --no-launch');
    print('  flutter-skill serve https://app.com --headless');
    print('');
    print('Options:');
    print('  --port=N       HTTP server port (default: 3000)');
    print('  --cdp-port=N   Chrome DevTools port (default: 9222)');
    print('  --headless     Run Chrome in headless mode');
    print('  --no-launch    Connect to existing Chrome instance');
    print('  --no-watch     Disable hot reload detection');
    print('');
    print('This starts a WebMCP-compatible server that auto-discovers');
    print('all interactive elements on the page and exposes them as tools.');
    print('Any MCP client can connect and control the app.');
    exit(1);
  }

  print('🚀 flutter-skill serve — Zero-Config WebMCP');
  print('');
  print('   URL: $url');
  print('   CDP Port: $cdpPort');
  print('   Server Port: $serverPort');
  print('   Headless: $headless');
  print('   Hot Reload Watch: $watch');
  print('');

  // Step 1: Connect via CDP (always connect to about:blank first to avoid
  // creating duplicate tabs when target URL redirects to a different subdomain)
  print('📡 Connecting to Chrome...');
  final cdp = CdpDriver(
    url: '', // Connect to any existing tab, don't create one for target URL
    port: cdpPort,
    launchChrome: launchChrome,
    headless: headless,
  );
  await cdp.connect();
  print('✅ Connected via CDP');

  // Step 1b: Navigate to target URL via smart navigation (reuses tabs by domain)
  if (url.isNotEmpty && url != 'about:blank') {
    await _navigateToUrl(cdp, url, cdpPort);
    await Future.delayed(const Duration(seconds: 2));
  }

  // Step 2: Initial tool discovery
  print('🔍 Scanning page for interactive elements...');
  var toolCache = await _discoverAndPrint(cdp);

  // Step 3: Set up hot reload detection
  if (watch) {
    print('👀 Watching for changes (HMR / hot reload / DOM mutations)...');
    await _setupHotReloadDetection(cdp);
  }

  // Step 4: Start HTTP server
  print('');
  print('═══════════════════════════════════════════════');
  print('  📋 WebMCP Server: http://localhost:$serverPort');
  print('');
  print('  Endpoints:');
  print('    GET  /tools/list     — List all discovered tools');
  print('    POST /tools/call     — Call a tool { name, arguments }');
  print('    GET  /snapshot       — Page text snapshot');
  print('    GET  /screenshot     — Page screenshot (JPEG)');
  print('    POST /navigate       — Navigate { url }');
  print('    POST /refresh        — Force re-scan tools');
  print('    GET  /health         — Server status');
  print('═══════════════════════════════════════════════');
  print('');
  print('Press Ctrl+C to stop.');

  final server = await HttpServer.bind(
    InternetAddress.anyIPv4,
    serverPort,
    shared:
        true, // SO_REUSEADDR — avoids "Address already in use" on TIME_WAIT sockets
  );

  // Shared mutable state
  final state = _ServeState(toolCache, DateTime.now(), cdpPort);

  // Background: poll for DOM changes
  if (watch) {
    Timer.periodic(const Duration(seconds: 2), (timer) async {
      try {
        final changed = await _checkForChanges(cdp);
        if (changed) {
          print('🔄 Page changed (hot reload?) — rescanning...');
          state.tools = await _discoverAndPrint(cdp);
          state.updatedAt = DateTime.now();
        }
      } catch (e) {
        // CDP connection may drop — try to recover
        if (e.toString().contains('-32000') ||
            e.toString().contains('Inspected target navigated or closed')) {
          print('⚠️ CDP target lost, attempting to reconnect...');
          await _reconnectCdpTarget(cdp, cdpPort,
              preferOrigin: state.lastNavigatedOrigin);
        }
      }
    });
  }

  await for (final request in server) {
    try {
      // Refresh tools on each request if stale (> 30s)
      if (DateTime.now().difference(state.updatedAt).inSeconds > 30) {
        try {
          state.tools = await _discoverTools(cdp);
          state.updatedAt = DateTime.now();
        } catch (e) {
          print('   ⚠️ Tool refresh failed: $e');
        }
      }
      await _handleRequest(request, cdp, state);
    } catch (e) {
      // Try to recover from CDP target loss on any request
      if (e.toString().contains('-32000') ||
          e.toString().contains('Inspected target navigated or closed')) {
        print('   ⚠️ CDP target lost, attempting to reconnect...');
        await _reconnectCdpTarget(cdp, state.cdpPort,
            preferOrigin: state.lastNavigatedOrigin);
      }
      print('   ❌ Request error: $e');
      try {
        request.response
          ..statusCode = 500
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'error': e.toString()}));
        await request.response.close();
      } catch (_) {}
    }
  }
}

/// Shared mutable state for the serve session
class _ServeState {
  List<Map<String, dynamic>> tools;
  DateTime updatedAt;
  final int cdpPort;
  String? lastNavigatedOrigin; // Track which origin we're connected to
  _ServeState(this.tools, this.updatedAt, this.cdpPort);
}

/// Reconnect to the CDP target after it navigates or closes.
/// If [preferOrigin] is set, prefer a tab matching that origin.
Future<void> _reconnectCdpTarget(CdpDriver cdp, int cdpPort,
    {String? preferOrigin}) async {
  try {
    await Future.delayed(const Duration(seconds: 1));
    final client = HttpClient();
    final request =
        await client.getUrl(Uri.parse('http://localhost:$cdpPort/json'));
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    final tabs = (jsonDecode(body) as List).cast<Map<String, dynamic>>();
    client.close();

    // Prefer tab matching the last navigated origin
    Map<String, dynamic>? pageTab;
    if (preferOrigin != null) {
      pageTab = tabs.cast<Map<String, dynamic>?>().firstWhere(
            (t) =>
                t!['type'] == 'page' &&
                (t['url'] as String? ?? '').startsWith(preferOrigin),
            orElse: () => null,
          );
    }
    // Fallback to first page tab
    pageTab ??= tabs.firstWhere(
      (t) => t['type'] == 'page',
      orElse: () => tabs.isNotEmpty ? tabs.first : <String, dynamic>{},
    );

    final wsUrl = pageTab['webSocketDebuggerUrl'] as String?;
    if (wsUrl != null && wsUrl.isNotEmpty) {
      await cdp.reconnectTo(wsUrl);
      print('   ✅ Reconnected to CDP target: ${pageTab['url']}');
    }
  } catch (e) {
    print('   ❌ Failed to reconnect CDP target: $e');
  }
}

/// Navigate to a URL — find an existing tab with matching origin and reconnect,
/// or navigate in current tab if no match found.
Future<void> _navigateToUrl(CdpDriver cdp, String url, int cdpPort) async {
  try {
    final targetUri = Uri.parse(url);
    final targetOrigin = '${targetUri.scheme}://${targetUri.host}';

    // Fetch all tabs
    final client = HttpClient();
    final request =
        await client.getUrl(Uri.parse('http://localhost:$cdpPort/json'));
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    final tabs = (jsonDecode(body) as List).cast<Map<String, dynamic>>();
    client.close();

    // Find tab with matching origin or same root domain
    final targetHost = targetUri.host;
    final targetParts = targetHost.split('.');
    final targetRoot = targetParts.length >= 2
        ? targetParts.sublist(targetParts.length - 2).join('.')
        : targetHost;

    Map<String, dynamic>? matchingTab;

    // 1. Exact origin match
    matchingTab = tabs.cast<Map<String, dynamic>?>().firstWhere(
          (t) =>
              t!['type'] == 'page' &&
              (t['url'] as String? ?? '').startsWith(targetOrigin),
          orElse: () => null,
        );

    // 2. Root domain match (e.g. passport.csdn.net → www.csdn.net)
    if (matchingTab == null) {
      matchingTab = tabs.cast<Map<String, dynamic>?>().firstWhere(
        (t) {
          if (t!['type'] != 'page') return false;
          final tabHost = Uri.tryParse(t['url']?.toString() ?? '')?.host ?? '';
          final tabParts = tabHost.split('.');
          final tabRoot = tabParts.length >= 2
              ? tabParts.sublist(tabParts.length - 2).join('.')
              : tabHost;
          return tabRoot == targetRoot && tabRoot.isNotEmpty;
        },
        orElse: () => null,
      );
    }

    if (matchingTab != null) {
      // Connect to existing tab with same origin/domain
      final wsUrl = matchingTab['webSocketDebuggerUrl'] as String?;
      if (wsUrl != null && wsUrl.isNotEmpty) {
        await cdp.reconnectTo(wsUrl);
        print('   ✅ Connected to existing tab: ${matchingTab['url']}');
      }
      final tabUrl = matchingTab['url'] as String? ?? '';
      if (tabUrl == url) {
        // Already on exact URL — skip navigation
      } else {
        // Navigate (even for root domain matches — user explicitly requested this URL)
        await cdp.call('Page.navigate', {'url': url});
        await Future.delayed(const Duration(seconds: 3));
        await _retryWithJsNavIfBroken(cdp, url);
      }
    } else {
      // No matching tab — navigate in current tab
      await cdp.call('Page.navigate', {'url': url});
      await Future.delayed(const Duration(seconds: 3));
      await _retryWithJsNavIfBroken(cdp, url);
      print('   ✅ Navigated current tab to: $url');
    }
  } catch (e) {
    print('   ⚠️ Smart navigate failed ($e), using direct navigate');
    await cdp.call('Page.navigate', {'url': url});
    await Future.delayed(const Duration(seconds: 3));
  }
}

/// Some SPAs (X/Twitter) detect CDP Page.navigate and serve static error pages
/// like "JavaScript is not available". If detected, retry via JS navigation
/// which triggers the SPA router instead of a full page reload.
/// Only triggers on definitive anti-bot error pages, NOT on slow-loading pages.
Future<void> _retryWithJsNavIfBroken(CdpDriver cdp, String url) async {
  try {
    final result = await cdp.evaluate('''
      (() => {
        const text = document.body?.innerText || '';
        // Only retry on definitive anti-bot/broken-JS error pages
        if (text.includes('JavaScript is not available') ||
            text.includes('Enable JavaScript') ||
            text.includes('JavaScript is disabled') ||
            text.includes('browser is not supported')) {
          return 'broken';
        }
        return 'ok';
      })()
    ''');
    final status = result['result']?['value'] as String? ?? 'ok';
    if (status == 'broken') {
      print(
          '   ⚠️ Anti-bot error page detected, retrying via JS navigation...');
      final escaped = url.replaceAll("'", "\\'");
      await cdp.evaluate("window.location.href = '$escaped'");
      await Future.delayed(const Duration(seconds: 4));
    }
  } catch (_) {
    // Ignore errors in detection — non-critical
  }
}

/// Handle HTTP requests
Future<void> _handleRequest(
  HttpRequest request,
  CdpDriver cdp,
  _ServeState state,
) async {
  final tools = state.tools;
  final path = request.uri.path;
  final method = request.method;
  final response = request.response;

  // CORS
  response.headers.add('Access-Control-Allow-Origin', '*');
  response.headers.add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  response.headers.add('Access-Control-Allow-Headers', 'Content-Type');

  if (method == 'OPTIONS') {
    response.statusCode = 200;
    await response.close();
    return;
  }

  switch (path) {
    case '/':
    case '/health':
      response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'status': 'ok',
          'service': 'flutter-skill-webmcp',
          'version': '0.8.5',
          'tools': tools.length,
          'capabilities': [
            'auto-discover',
            'hot-reload',
            'zero-config',
            'snapshot',
            'screenshot',
          ],
        }));
      await response.close();

    case '/tools/list':
    case '/tools':
      final toolDefs = tools.map(_toMcpToolDef).toList();
      // Add built-in CDP tools
      toolDefs.addAll(_builtInCdpToolDefs());
      response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'tools': toolDefs}));
      await response.close();

    case '/tools/call':
      if (method != 'POST') {
        response
          ..statusCode = 405
          ..write('POST required');
        await response.close();
        return;
      }
      final body = jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, dynamic>;
      final toolName = body['name'] as String?;
      final toolArgs =
          (body['arguments'] ?? body['params'] ?? {}) as Map<String, dynamic>;

      if (toolName == null) {
        response
          ..statusCode = 400
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'error': 'Missing "name" field'}));
        await response.close();
        return;
      }

      print('   🔧 Calling tool: $toolName');

      // Built-in tools handled by serve
      if (toolName == 'reset_app') {
        final clearStorage = toolArgs['clear_storage'] ?? true;
        final clearCookies = toolArgs['clear_cookies'] ?? true;
        final actions = <String>[];
        if (clearStorage) {
          await cdp.call('Runtime.evaluate', {
            'expression': 'localStorage.clear(); sessionStorage.clear();',
            'returnByValue': true,
          });
          actions.add('storage cleared');
        }
        if (clearCookies) {
          try {
            await cdp.call('Network.enable');
            await cdp.call('Network.clearBrowserCookies');
          } catch (_) {}
          actions.add('cookies cleared');
        }
        await cdp.call('Page.reload', {'ignoreCache': true});
        await Future.delayed(const Duration(seconds: 2));
        // Re-scan tools after reset
        state.tools = await _discoverTools(cdp);
        state.updatedAt = DateTime.now();
        actions.add('page reloaded');
        response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({
            'success': true,
            'actions': actions,
            'tools': state.tools.length,
          }));
        await response.close();
        return;
      }

      if (toolName == 'snapshot') {
        // Redirect to /snapshot
        final result = await cdp.call('Runtime.evaluate', {
          'expression': _snapshotJs,
          'returnByValue': true,
        });
        final text = result['result']?['value'] as String? ?? '';
        response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'snapshot': text, 'length': text.length}));
        await response.close();
        return;
      }

      // Route built-in CDP tools that need native Dart handling
      final builtInResult =
          await _handleBuiltInCdpTool(cdp, toolName, toolArgs, state);
      if (builtInResult != null) {
        response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(builtInResult));
        await response.close();
        return;
      }

      final result = await cdp.callTool(toolName, toolArgs);
      response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(result));
      await response.close();

    case '/snapshot':
      // Text-based page snapshot (token efficient)
      final result = await cdp.call('Runtime.evaluate', {
        'expression': _snapshotJs,
        'returnByValue': true,
      });
      final text = result['result']?['value'] as String? ?? '';
      response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'snapshot': text, 'length': text.length}));
      await response.close();

    case '/screenshot':
      final data = await cdp.takeScreenshot(quality: 0.8, maxWidth: 1280);
      if (data != null) {
        response
          ..statusCode = 200
          ..headers.set('Content-Type', 'image/jpeg')
          ..add(base64Decode(data));
      } else {
        response
          ..statusCode = 500
          ..write('Screenshot failed');
      }
      await response.close();

    case '/navigate':
      if (method != 'POST') {
        response
          ..statusCode = 405
          ..write('POST required');
        await response.close();
        return;
      }
      final body = jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, dynamic>;
      final navUrl = body['url'] as String?;
      if (navUrl == null) {
        response
          ..statusCode = 400
          ..write('Missing "url" field');
        await response.close();
        return;
      }
      print('   🌐 Navigating to: $navUrl');
      try {
        // Track the origin so reconnect logic prefers this tab
        final navUri = Uri.parse(navUrl);
        state.lastNavigatedOrigin = '${navUri.scheme}://${navUri.host}';
        // Navigate in the current tab — find matching tab or open new one
        await _navigateToUrl(cdp, navUrl, state.cdpPort);
        // Re-setup observers and re-scan tools
        await _setupHotReloadDetection(cdp);
        state.tools = await _discoverAndPrint(cdp);
        state.updatedAt = DateTime.now();
        response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(
              jsonEncode({'navigated': navUrl, 'tools': state.tools.length}));
      } catch (e) {
        // Try to recover from CDP target loss
        if (e.toString().contains('-32000') ||
            e.toString().contains('Inspected target navigated or closed')) {
          print('   ⚠️ CDP target lost during navigation, reconnecting...');
          await Future.delayed(const Duration(seconds: 1));
          await _reconnectCdpTarget(cdp, state.cdpPort);
          state.tools = await _discoverAndPrint(cdp);
          state.updatedAt = DateTime.now();
          response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({
              'navigated': navUrl,
              'tools': state.tools.length,
              'reconnected': true
            }));
        } else {
          response
            ..statusCode = 500
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'error': e.toString()}));
        }
      }
      await response.close();

    case '/refresh':
      print('   🔄 Force refresh tools');
      state.tools = await _discoverAndPrint(cdp);
      state.updatedAt = DateTime.now();
      response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'tools': state.tools.length, 'refreshed': true}));
      await response.close();

    default:
      response
        ..statusCode = 404
        ..write('Not found: $path');
      await response.close();
  }
}

/// Convert internal tool format to MCP tool definition
Map<String, dynamic> _toMcpToolDef(Map<String, dynamic> tool) {
  final params = tool['params'] as Map<String, dynamic>? ?? {};
  final properties = <String, dynamic>{};
  final required = <String>[];

  params.forEach((key, value) {
    if (value is Map<String, dynamic>) {
      properties[key] = {
        'type': value['type'] ?? 'string',
        'description': value['description'] ?? '',
      };
      if (value['required'] == true) required.add(key);
    }
  });

  return {
    'name': tool['name'],
    'description': tool['description'] ?? '',
    'inputSchema': {
      'type': 'object',
      'properties': properties,
      if (required.isNotEmpty) 'required': required,
    },
  };
}

/// Discover tools and print summary
Future<List<Map<String, dynamic>>> _discoverAndPrint(CdpDriver cdp) async {
  final tools = await _discoverTools(cdp);

  // Group by source
  final bySource = <String, int>{};
  for (final t in tools) {
    final source = t['source'] as String? ?? 'unknown';
    bySource[source] = (bySource[source] ?? 0) + 1;
  }

  print('   📦 ${tools.length} tools discovered:');
  bySource.forEach((source, count) {
    final icon = switch (source) {
      'auto-ui' => '🔍 UI elements',
      'auto-form' => '📝 Forms',
      'js-registered' => '📦 JS registered',
      'data-mcp-tool' => '🏷️ Annotated',
      'well-known' => '🌐 .well-known',
      'link-manifest' => '🔗 Manifest',
      _ => '❓ $source',
    };
    print('      $icon: $count');
  });

  return tools;
}

/// Raw tool discovery
Future<List<Map<String, dynamic>>> _discoverTools(CdpDriver cdp) async {
  final result = await cdp.discoverTools();
  return (result['tools'] as List?)?.cast<Map<String, dynamic>>() ?? [];
}

/// Set up hot reload / HMR / DOM mutation detection
Future<void> _setupHotReloadDetection(CdpDriver cdp) async {
  await cdp.call('Runtime.evaluate', {
    'expression': '''
    (() => {
      if (window.__fs_serve_observer__) return 'already active';

      window.__fs_dom_change_count__ = 0;
      window.__fs_last_checked__ = 0;

      // 1. DOM MutationObserver — catches all framework renders
      const observer = new MutationObserver((mutations) => {
        const significant = mutations.some(m =>
          m.type === 'childList' && (m.addedNodes.length > 0 || m.removedNodes.length > 0)
        );
        if (significant) window.__fs_dom_change_count__++;
      });
      observer.observe(document.body || document.documentElement, {
        childList: true,
        subtree: true,
      });
      window.__fs_serve_observer__ = observer;

      // 2. Navigation events
      window.addEventListener('popstate', () => window.__fs_dom_change_count__++);
      window.addEventListener('hashchange', () => window.__fs_dom_change_count__++);

      // 3. Vite HMR
      try {
        if (import.meta?.hot) {
          import.meta.hot.on('vite:afterUpdate', () => window.__fs_dom_change_count__ += 10);
          import.meta.hot.on('vite:fullReload', () => window.__fs_dom_change_count__ += 10);
        }
      } catch(e) {}

      // 4. Webpack HMR
      try {
        if (module?.hot) {
          module.hot.addStatusHandler((status) => {
            if (status === 'apply') window.__fs_dom_change_count__ += 10;
          });
        }
      } catch(e) {}

      // 5. React Fast Refresh (detect re-renders)
      // React DevTools hook fires on commit
      try {
        if (window.__REACT_DEVTOOLS_GLOBAL_HOOK__) {
          const orig = window.__REACT_DEVTOOLS_GLOBAL_HOOK__.onCommitFiberRoot;
          if (orig) {
            window.__REACT_DEVTOOLS_GLOBAL_HOOK__.onCommitFiberRoot = function(...args) {
              window.__fs_dom_change_count__++;
              return orig.apply(this, args);
            };
          }
        }
      } catch(e) {}

      // 6. Flutter Web hot reload (service worker message)
      try {
        navigator.serviceWorker?.addEventListener('message', (e) => {
          if (e.data?.type === 'FLUTTER_REASSEMBLE') {
            window.__fs_dom_change_count__ += 10;
          }
        });
      } catch(e) {}

      return 'observers installed';
    })()
    ''',
    'returnByValue': true,
  });
}

/// Check if page changed since last check
Future<bool> _checkForChanges(CdpDriver cdp) async {
  final result = await cdp.call('Runtime.evaluate', {
    'expression': '''
    (() => {
      const c = window.__fs_dom_change_count__ || 0;
      const last = window.__fs_last_checked__ || 0;
      window.__fs_last_checked__ = c;
      return c > last;
    })()
    ''',
    'returnByValue': true,
  });
  return result['result']?['value'] == true;
}

/// JS for text-based page snapshot
const _snapshotJs = '''
(() => {
  const lines = [];
  const walk = (node, depth) => {
    if (node.nodeType === 3) {
      const t = node.textContent.trim();
      if (t) lines.push('  '.repeat(depth) + t);
      return;
    }
    if (node.nodeType !== 1) return;
    const el = node;
    const tag = el.tagName.toLowerCase();
    if (['script','style','noscript','svg','path'].includes(tag)) return;
    if (el.hidden || el.style.display === 'none') return;

    const role = el.getAttribute('role') || '';
    const label = el.getAttribute('aria-label') || '';
    const href = el.getAttribute('href') || '';

    let prefix = '';
    if (tag === 'button' || role === 'button') prefix = '[button] ';
    else if (tag === 'a' && href) prefix = '[link] ';
    else if (tag === 'input') prefix = '[input:' + (el.type||'text') + '] ';
    else if (tag === 'textarea') prefix = '[textarea] ';
    else if (tag === 'select') prefix = '[select] ';
    else if (tag === 'img') { lines.push('  '.repeat(depth) + '[img] ' + (el.alt||'')); return; }
    else if (['h1','h2','h3','h4','h5','h6'].includes(tag)) prefix = '[' + tag + '] ';

    if (prefix && label) {
      lines.push('  '.repeat(depth) + prefix + label);
    }

    for (const child of el.childNodes) walk(child, depth + (prefix ? 1 : 0));
  };
  walk(document.body, 0);
  return lines.join('\\n');
})()
''';

/// Built-in CDP tool definitions for /tools/list
List<Map<String, dynamic>> _builtInCdpToolDefs() => [
      {
        'name': 'tap',
        'description':
            'Tap/click an element by text, CSS selector, ref, or x,y coordinates',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'text': {
              'type': 'string',
              'description': 'Visible text of element to tap'
            },
            'selector': {'type': 'string', 'description': 'CSS selector'},
            'key': {
              'type': 'string',
              'description': 'CSS selector (alias for selector)'
            },
            'ref': {
              'type': 'string',
              'description': 'Element ref from snapshot'
            },
            'x': {'type': 'number', 'description': 'X coordinate'},
            'y': {'type': 'number', 'description': 'Y coordinate'},
          }
        }
      },
      {
        'name': 'type_text',
        'description':
            'Type text via keyboard (into focused element or specified selector)',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'text': {'type': 'string', 'description': 'Text to type'},
          },
          'required': ['text']
        }
      },
      {
        'name': 'screenshot',
        'description': 'Take a screenshot of the current page',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'quality': {
              'type': 'number',
              'description': 'JPEG quality 0.0-1.0 (default 0.8)'
            },
            'max_width': {
              'type': 'integer',
              'description': 'Max width in pixels (default 1280)'
            },
          }
        }
      },
      {
        'name': 'snapshot',
        'description':
            'Get a text-based accessibility snapshot of the page (token-efficient)',
        'inputSchema': {'type': 'object', 'properties': {}}
      },
      {
        'name': 'upload_file',
        'description':
            'Upload file(s) to an input[type=file] element. Supports Shadow DOM.',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'selector': {
              'type': 'string',
              'description':
                  'CSS selector for file input (default: input[type="file"])'
            },
            'files': {
              'type': 'array',
              'items': {'type': 'string'},
              'description': 'List of absolute file paths to upload'
            },
          },
          'required': ['files']
        }
      },
      {
        'name': 'navigate',
        'description':
            'Navigate to a URL (finds matching tab or navigates current tab)',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'url': {'type': 'string', 'description': 'URL to navigate to'},
          },
          'required': ['url']
        }
      },
      {
        'name': 'evaluate',
        'description':
            'Execute JavaScript in the browser and return the result',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'expression': {
              'type': 'string',
              'description': 'JavaScript expression to evaluate'
            },
          },
          'required': ['expression']
        }
      },
      {
        'name': 'scroll',
        'description': 'Scroll to an element by CSS selector or text',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'key': {
              'type': 'string',
              'description': 'CSS selector to scroll to'
            },
            'text': {
              'type': 'string',
              'description': 'Text of element to scroll to'
            },
          }
        }
      },
      {
        'name': 'hover',
        'description': 'Hover over an element',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'key': {'type': 'string', 'description': 'CSS selector'},
            'text': {'type': 'string', 'description': 'Visible text'},
            'ref': {
              'type': 'string',
              'description': 'Element ref from snapshot'
            },
          }
        }
      },
      {
        'name': 'press_key',
        'description': 'Press a keyboard key (Enter, Tab, Escape, etc.)',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'key': {
              'type': 'string',
              'description':
                  'Key name (Enter, Tab, Escape, Backspace, ArrowDown, etc.)'
            },
            'modifiers': {
              'type': 'string',
              'description':
                  'Comma-separated modifiers: Alt, Control, Meta, Shift'
            },
          },
          'required': ['key']
        }
      },
      {
        'name': 'select_option',
        'description': 'Select an option from a <select> dropdown',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'selector': {
              'type': 'string',
              'description': 'CSS selector for the select element'
            },
            'value': {'type': 'string', 'description': 'Value to select'},
          },
          'required': ['selector', 'value']
        }
      },
      {
        'name': 'get_text',
        'description': 'Get visible text of the page or a specific element',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'selector': {
              'type': 'string',
              'description': 'Optional CSS selector to scope text extraction'
            },
          }
        }
      },
      {
        'name': 'get_title',
        'description': 'Get the page title',
        'inputSchema': {'type': 'object', 'properties': {}}
      },
      {
        'name': 'get_url',
        'description': 'Get the current page URL',
        'inputSchema': {'type': 'object', 'properties': {}}
      },
      {
        'name': 'get_cookies',
        'description': 'Get all browser cookies for the current page',
        'inputSchema': {'type': 'object', 'properties': {}}
      },
      {
        'name': 'set_cookie',
        'description': 'Set a browser cookie',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'name': {'type': 'string'},
            'value': {'type': 'string'},
            'domain': {'type': 'string'},
          },
          'required': ['name', 'value']
        }
      },
      {
        'name': 'go_back',
        'description': 'Navigate back in browser history',
        'inputSchema': {'type': 'object', 'properties': {}}
      },
      {
        'name': 'go_forward',
        'description': 'Navigate forward in browser history',
        'inputSchema': {'type': 'object', 'properties': {}}
      },
      {
        'name': 'wait',
        'description': 'Wait for a specified duration',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'ms': {
              'type': 'integer',
              'description': 'Milliseconds to wait (default 1000)'
            },
          }
        }
      },
      {
        'name': 'reset_app',
        'description': 'Clear storage, cookies, and reload the page',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'clear_storage': {
              'type': 'boolean',
              'description': 'Clear localStorage/sessionStorage (default true)'
            },
            'clear_cookies': {
              'type': 'boolean',
              'description': 'Clear cookies (default true)'
            },
          }
        }
      },
    ];

/// Handle built-in CDP tools that require native Dart methods.
/// Returns null if the tool is not a built-in CDP tool.
Future<Map<String, dynamic>?> _handleBuiltInCdpTool(
    CdpDriver cdp, String toolName, Map<String, dynamic> args,
    [_ServeState? state]) async {
  switch (toolName) {
    case 'upload_file':
      final selector = args['selector'] as String? ?? 'input[type="file"]';
      final files = (args['files'] as List<dynamic>?)?.cast<String>() ?? [];
      return await cdp.uploadFile(selector, files);

    case 'tap':
      final x = args['x'] as num?;
      final y = args['y'] as num?;
      if (x != null && y != null) {
        await cdp.tapAt(x.toDouble(), y.toDouble());
        return {'success': true, 'x': x, 'y': y};
      }
      return await cdp.tap(
        key: args['selector'] as String? ?? args['key'] as String?,
        text: args['text'] as String?,
        ref: args['ref'] as String?,
      );

    case 'type_text':
    case 'enter_text':
      final text = args['text'] as String? ?? '';
      await cdp.typeText(text);
      return {'success': true, 'text': text};

    case 'snapshot':
      final snapResult = await cdp.call('Runtime.evaluate', {
        'expression': _snapshotJs,
        'returnByValue': true,
      });
      final snapText = snapResult['result']?['value'] as String? ?? '';
      return {'success': true, 'snapshot': snapText, 'length': snapText.length};

    case 'screenshot':
      final quality = (args['quality'] as num?)?.toDouble() ?? 0.8;
      final maxWidth = (args['max_width'] as num?)?.toInt() ?? 1280;
      final data =
          await cdp.takeScreenshot(quality: quality, maxWidth: maxWidth);
      if (data != null) {
        return {'success': true, 'base64': data, 'format': 'jpeg'};
      }
      return {'success': false, 'error': 'Screenshot failed'};

    case 'scroll':
      return await cdp.scrollTo(
        key: args['selector'] as String? ?? args['key'] as String?,
        text: args['text'] as String?,
      );

    case 'navigate':
      final url = args['url'] as String?;
      if (url == null) return {'success': false, 'error': 'Missing url'};
      if (state != null) {
        final navUri = Uri.parse(url);
        state.lastNavigatedOrigin = '${navUri.scheme}://${navUri.host}';
        await _navigateToUrl(cdp, url, state.cdpPort);
        // Re-scan tools after navigation
        state.tools = await _discoverTools(cdp);
        state.updatedAt = DateTime.now();
      } else {
        await cdp.navigate(url);
      }
      return {'success': true, 'url': url};

    case 'get_text':
    case 'get_visible_text':
      final selector = args['selector'] as String?;
      final text = await cdp.getVisibleText(selector: selector);
      return {'success': true, 'text': text};

    case 'evaluate':
    case 'eval':
      final expression =
          args['expression'] as String? ?? args['code'] as String? ?? '';
      final result = await cdp.call('Runtime.evaluate', {
        'expression': expression,
        'returnByValue': true,
        'awaitPromise': true,
      });
      return {'success': true, 'result': result['result']?['value']};

    case 'wait':
      final ms = (args['ms'] as num?)?.toInt() ??
          (args['milliseconds'] as num?)?.toInt() ??
          1000;
      await Future.delayed(Duration(milliseconds: ms));
      return {'success': true, 'waited_ms': ms};

    case 'press_key':
      final key = args['key'] as String? ?? '';
      final rawMod = args['modifiers'];
      final modifiers = rawMod is List
          ? rawMod.cast<String>()
          : rawMod is String
              ? rawMod
                  .split(',')
                  .map((s) => s.trim())
                  .where((s) => s.isNotEmpty)
                  .toList()
              : null;
      await cdp.pressKey(key, modifiers: modifiers);
      return {'success': true, 'key': key};

    case 'hover':
      return await cdp.hover(
        key: args['selector'] as String? ?? args['key'] as String?,
        text: args['text'] as String?,
        ref: args['ref'] as String?,
      );

    case 'select_option':
      final selector = args['selector'] as String? ?? 'select';
      final value = args['value'] as String? ?? '';
      await cdp.selectOption(selector, value);
      return {'success': true, 'selector': selector, 'value': value};

    case 'get_cookies':
      return await cdp.getCookies();

    case 'set_cookie':
      final name = args['name'] as String? ?? '';
      final value = args['value'] as String? ?? '';
      final domain = args['domain'] as String?;
      return await cdp.setCookie(name, value, domain: domain ?? '');

    case 'go_back':
      final went = await cdp.goBack();
      return {'success': went};

    case 'go_forward':
      final went = await cdp.goForward();
      return {'success': went};

    case 'get_title':
      final title = await cdp.getTitle();
      return {'success': true, 'title': title};

    case 'get_url':
      final result = await cdp.call('Runtime.evaluate', {
        'expression': 'window.location.href',
        'returnByValue': true,
      });
      return {'success': true, 'url': result['result']?['value']};

    case 'qr_login_start':
      return await _handleQrLoginStartServe(cdp, args);

    case 'qr_login_wait':
      return await _handleQrLoginWaitServe(cdp, args);

    default:
      return null; // Not a built-in tool
  }
}

/// QR login start — detect and screenshot QR code for remote scanning.
Future<Map<String, dynamic>> _handleQrLoginStartServe(
    CdpDriver cdp, Map<String, dynamic> args) async {
  final selector = args['selector'] as String?;
  final fullPage = args['full_page'] as bool? ?? false;

  String? qrBase64;

  if (!fullPage) {
    final detectJs = selector != null
        ? '''
      (() => {
        const el = document.querySelector(${jsonEncode(selector)});
        if (!el) return null;
        const r = el.getBoundingClientRect();
        return { x: r.x, y: r.y, width: r.width, height: r.height, selector: ${jsonEncode(selector)} };
      })()
      '''
        : '''
      (() => {
        const selectors = [
          'img[src*="qr"]', 'img[alt*="qr"]', 'img[alt*="QR"]',
          'img[src*="QR"]', 'img[class*="qr"]', 'img[class*="QR"]',
          'canvas[class*="qr"]', 'canvas[class*="QR"]',
          '[class*="qrcode"]', '[class*="QRCode"]', '[class*="qr-code"]',
          '[id*="qr"]', '[id*="QR"]',
          'img[src*="login"]canvas',
          '[class*="web_qrcode"]', '[class*="scan"]',
          '.qrcode-img', '.login-qr', '.qr-image',
        ];
        for (const sel of selectors) {
          const el = document.querySelector(sel);
          if (el) {
            const r = el.getBoundingClientRect();
            if (r.width > 50 && r.height > 50) {
              return { x: r.x, y: r.y, width: r.width, height: r.height, selector: sel };
            }
          }
        }
        for (const img of document.querySelectorAll('img, canvas')) {
          const r = img.getBoundingClientRect();
          if (r.width > 100 && r.height > 100 && Math.abs(r.width - r.height) < 30) {
            return { x: r.x, y: r.y, width: r.width, height: r.height, selector: 'auto-square' };
          }
        }
        return null;
      })()
      ''';

    final detectResult = await cdp.evaluate(detectJs);
    final qrRect = detectResult['result']?['value'];

    if (qrRect is Map) {
      final x = (qrRect['x'] as num).toDouble();
      final y = (qrRect['y'] as num).toDouble();
      final w = (qrRect['width'] as num).toDouble();
      final h = (qrRect['height'] as num).toDouble();
      final pad = 10.0;

      qrBase64 = await cdp.takeRegionScreenshot(
        (x - pad).clamp(0, double.infinity),
        (y - pad).clamp(0, double.infinity),
        w + pad * 2,
        h + pad * 2,
      );

      if (qrBase64 != null) {
        final urlResult = await cdp.evaluate('window.location.href');
        final currentUrl = urlResult['result']?['value']?.toString() ?? '';
        final cookieResult = await cdp.evaluate('document.cookie.length');
        final cookieLen = cookieResult['result']?['value'] ?? 0;

        return {
          'success': true,
          'qr_image': qrBase64,
          'format': 'jpeg',
          'qr_bounds': {'x': x, 'y': y, 'width': w, 'height': h},
          'matched_selector': qrRect['selector'] ?? selector,
          'initial_url': currentUrl,
          'initial_cookie_length': cookieLen,
          'hint':
              'Send this base64 image to the user for scanning. Then call qr_login_wait to detect login success.',
        };
      }
    }
  }

  // Fallback: full page screenshot
  qrBase64 = await cdp.takeScreenshot(quality: 0.9);
  if (qrBase64 == null) {
    return {'success': false, 'error': 'Failed to take screenshot'};
  }

  final urlResult = await cdp.evaluate('window.location.href');
  final currentUrl = urlResult['result']?['value']?.toString() ?? '';
  final cookieResult = await cdp.evaluate('document.cookie.length');
  final cookieLen = cookieResult['result']?['value'] ?? 0;

  return {
    'success': true,
    'qr_image': qrBase64,
    'format': 'jpeg',
    'full_page': true,
    'initial_url': currentUrl,
    'initial_cookie_length': cookieLen,
    'hint': 'QR element not auto-detected; returning full page screenshot.',
  };
}

/// QR login wait — poll until login succeeds.
Future<Map<String, dynamic>> _handleQrLoginWaitServe(
    CdpDriver cdp, Map<String, dynamic> args) async {
  final timeoutMs = args['timeout_ms'] as int? ?? 120000;
  final pollMs = args['poll_ms'] as int? ?? 1000;
  final initialUrl = args['initial_url'] as String?;
  final initialCookieLen = args['initial_cookie_length'] as int? ?? 0;
  final successUrlPattern = args['success_url_pattern'] as String?;
  final successText = args['success_text'] as String?;
  final qrSelector = args['qr_selector'] as String?;

  final sw = Stopwatch()..start();

  while (sw.elapsedMilliseconds < timeoutMs) {
    await Future.delayed(Duration(milliseconds: pollMs));

    try {
      final urlResult = await cdp.evaluate('window.location.href');
      final currentUrl = urlResult['result']?['value']?.toString() ?? '';

      // Check URL changed
      if (initialUrl != null && currentUrl != initialUrl) {
        if (successUrlPattern != null) {
          if (RegExp(successUrlPattern).hasMatch(currentUrl)) {
            return {
              'success': true,
              'method': 'url_pattern_match',
              'url': currentUrl,
              'waited_ms': sw.elapsedMilliseconds,
            };
          }
        } else {
          return {
            'success': true,
            'method': 'url_changed',
            'previous_url': initialUrl,
            'url': currentUrl,
            'waited_ms': sw.elapsedMilliseconds,
          };
        }
      }

      // Check cookies changed
      final cookieResult = await cdp.evaluate('document.cookie.length');
      final currentCookieLen = (cookieResult['result']?['value'] as int?) ?? 0;
      if (currentCookieLen > initialCookieLen + 20) {
        return {
          'success': true,
          'method': 'cookie_changed',
          'cookie_length_delta': currentCookieLen - initialCookieLen,
          'url': currentUrl,
          'waited_ms': sw.elapsedMilliseconds,
        };
      }

      // Check QR element disappeared
      if (qrSelector != null) {
        final qrCheck = await cdp.evaluate(
            'document.querySelector(${jsonEncode(qrSelector)}) === null');
        if (qrCheck['result']?['value'] == true) {
          return {
            'success': true,
            'method': 'qr_disappeared',
            'url': currentUrl,
            'waited_ms': sw.elapsedMilliseconds,
          };
        }
      }

      // Check success text
      if (successText != null) {
        final textCheck = await cdp.evaluate(
            'document.body.innerText.includes(${jsonEncode(successText)})');
        if (textCheck['result']?['value'] == true) {
          return {
            'success': true,
            'method': 'success_text_found',
            'text': successText,
            'url': currentUrl,
            'waited_ms': sw.elapsedMilliseconds,
          };
        }
      }
    } catch (e) {
      if (sw.elapsedMilliseconds > 5000) {
        return {
          'success': true,
          'method': 'connection_disrupted',
          'note': 'Page may have redirected during login',
          'waited_ms': sw.elapsedMilliseconds,
          'error': e.toString(),
        };
      }
    }
  }

  return {
    'success': false,
    'method': 'timeout',
    'waited_ms': timeoutMs,
    'hint':
        'QR code may have expired. Call qr_login_start again for a fresh code.',
  };
}

/// Check if Chrome is already running on the specified port
Future<bool> _checkForExistingChrome(int port) async {
  try {
    final uri = Uri.parse('http://127.0.0.1:$port/json');
    final client = HttpClient();
    final request = await client.getUrl(uri);
    request.headers.set('Accept', 'application/json');
    final response = await request.close();
    return response.statusCode == 200;
  } catch (e) {
    return false;
  }
}
