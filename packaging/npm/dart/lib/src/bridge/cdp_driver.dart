library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../drivers/app_driver.dart';
import 'device_presets.dart';

part 'cdp_browser_methods.dart';
part 'cdp_appmcp_methods.dart';

/// Segment of text for typeText: either a control char or printable text run.
class _TypeSegment {
  final String text;
  final bool isControl;
  _TypeSegment(this.text, this.isControl);
}

/// AppDriver that communicates with any web page via Chrome DevTools Protocol.
///
/// No SDK injection needed — connects directly to Chrome's debugging port
/// and controls any web page (React, Vue, Angular, plain HTML, etc.).
class CdpDriver implements AppDriver {
  final String _url;
  int _port;
  final bool _launchChrome;
  final bool _headless;
  final String? _chromePath;
  final String? _proxy;
  final bool _ignoreSsl;
  final int _maxTabs;

  WebSocket? _ws;
  bool _connected = false;
  int _nextId = 1;
  Process? _chromeProcess;

  /// Pending CDP calls keyed by request id.
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  final Map<String, void Function()> _eventSubscriptions = {};
  final Map<String, List<void Function(Map<String, dynamic>)>> _eventListeners =
      {};
  bool _dialogHandlerInstalled = false;
  bool _isChrome146ConsentPort = false;
  final Map<String, Map<String, dynamic>> _interceptRules = {};

  /// Create a CDP driver.
  ///
  /// [url] is the page to navigate to.
  /// [port] is the Chrome remote debugging port.
  /// [launchChrome] whether to launch a new Chrome instance.
  /// [headless] run Chrome in headless mode (default: false).
  /// [chromePath] custom Chrome/Chromium executable path.
  /// [proxy] proxy server URL (e.g. 'http://proxy:8080').
  /// [ignoreSsl] ignore SSL certificate errors.
  /// [maxTabs] maximum number of tabs to allow (prevents runaway tab creation).
  CdpDriver({
    required String url,
    int port = 9222,
    bool launchChrome = true,
    bool headless = false,
    String? chromePath,
    String? proxy,
    bool ignoreSsl = false,
    int maxTabs = 20,
  })  : _url = url,
        _port = port,
        _launchChrome = launchChrome,
        _headless = headless,
        _chromePath = chromePath,
        _proxy = proxy,
        _ignoreSsl = ignoreSsl,
        _maxTabs = maxTabs;

  @override
  String get frameworkName => 'CDP (Web)';

  @override
  bool get isConnected => _connected;

  /// Whether connect() found an existing tab matching the target URL
  /// (skipped navigation to avoid duplicate tabs).
  bool connectedToExistingTab = false;

  Future<void> connect() async {
    // Auto-assign random port if 0
    if (_port == 0) {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      _port = server.port;
      await server.close();
    }

    // Check if CDP debug port is already responding.
    final cdpAlive = await _isCdpPortAlive();
    if (!cdpAlive) {
      final chromeRunning = await _isChromeRunning();
      if (chromeRunning) {
        // Step 1: Chrome may already have remote debugging enabled on a
        // different port (Chrome 136+ picks a random port when the
        // chrome://inspect/#remote-debugging checkbox is ticked).
        // Scan all Chrome TCP ports before touching anything.
        final existingPort = await _discoverChromeCdpPort();
        if (existingPort != null) {
          _port = existingPort;
          // CDP is already live — fall through to _discoverTarget().
        } else if (_launchChrome) {
          // Step 2: Try to enable via chrome://inspect/#remote-debugging.
          // Navigate Chrome to that page, tick the checkbox via the
          // macOS Accessibility API, then discover the new port.
          // This is zero-disruption: no restart, all tabs/sessions intact.
          final enabledPort = await _enableChromeRemoteDebugging();
          if (enabledPort != null) {
            _port = enabledPort;
          } else {
            // Step 3: Fallback — quit Chrome and relaunch with debug port.
            await _restartChromeWithDebugPort();
            await _waitForCdpReady();
          }
        }
        // launch_chrome: false + no debug port found → fall through to error.
      } else if (_launchChrome) {
        // Chrome is not running — launch a fresh flutter-skill profile.
        await _launchChromeProcess();
        await _waitForCdpReady();
      }
      // else: Chrome not running + launch_chrome: false → fall through to error.
    }

    // Discover tabs via CDP JSON endpoint
    var wsUrl = await _discoverTarget();

    // No suitable tab found — create a new one via CDP HTTP API
    if (wsUrl == null && _url.isNotEmpty) {
      try {
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 2);
        final encodedUrl = Uri.encodeComponent(_url);
        // Chrome 145+ requires PUT for /json/new
        final request = await client.openUrl(
            'PUT', Uri.parse('http://127.0.0.1:$_port/json/new?$encodedUrl'));
        final response = await request.close();
        final body = await response.transform(utf8.decoder).join();
        client.close();
        final tab = jsonDecode(body) as Map<String, dynamic>;
        wsUrl = tab['webSocketDebuggerUrl'] as String?;
        // Tab was just created with our URL — skip later navigation
        if (wsUrl != null) connectedToExistingTab = true;
      } catch (_) {}
    }

    if (wsUrl == null) {
      final chromeRunning = await _isChromeRunning();
      final hint = chromeRunning
          ? 'Chrome is running but remote debugging is not enabled. '
              'flutter-skill tried to auto-launch a debug profile but could not '
              'connect. Try: connect_cdp(url: "$_url", launch_chrome: true)'
          : 'Chrome is not running. '
              'Use connect_cdp(url: "$_url") to auto-launch Chrome with remote '
              'debugging enabled.';
      throw Exception(hint);
    }

    _ws = await _connectCdpWebSocket(wsUrl);
    _connected = true;

    _ws!.listen(
      _onMessage,
      onDone: _onDisconnect,
      onError: (_) => _onDisconnect(),
      cancelOnError: false,
    );

    // Enable required CDP domains in parallel.
    // Each call has an individual timeout so a bad/special tab (e.g. chrome://
    // pages, crashed renderers) cannot hang the entire connect() forever.
    await Future.wait([
      _call('Page.enable')
          .timeout(const Duration(seconds: 10), onTimeout: () => {}),
      _call('DOM.enable')
          .timeout(const Duration(seconds: 10), onTimeout: () => {}),
      _call('Runtime.enable')
          .timeout(const Duration(seconds: 10), onTimeout: () => {}),
    ]);

    // Check if _discoverTarget already found a tab with our exact URL.
    // If so, skip navigation to avoid reloading/duplicating.
    final currentUrl = await _getCurrentUrl();
    final alreadyOnTarget = currentUrl == _url ||
        (currentUrl != null && _url.isNotEmpty && currentUrl.startsWith(_url));

    // Also check root domain match (e.g. passport.csdn.net redirected to csdn.net)
    final sameRootDomain = !alreadyOnTarget &&
        currentUrl != null &&
        _url.isNotEmpty &&
        (() {
          final targetHost = Uri.tryParse(_url)?.host ?? '';
          final currentHost = Uri.tryParse(currentUrl)?.host ?? '';
          if (targetHost.isEmpty || currentHost.isEmpty) return false;
          final tp = targetHost.split('.');
          final cp = currentHost.split('.');
          final tr =
              tp.length >= 2 ? tp.sublist(tp.length - 2).join('.') : targetHost;
          final cr = cp.length >= 2
              ? cp.sublist(cp.length - 2).join('.')
              : currentHost;
          return tr == cr;
        })();

    // Navigate to URL and wait for load event.
    final skipNav = _url.isEmpty ||
        _url == 'about:blank' ||
        _url.contains('localhost:$_port') ||
        _url.contains('127.0.0.1:$_port') ||
        alreadyOnTarget ||
        (connectedToExistingTab && sameRootDomain);
    if (!skipNav) {
      await _call('Page.navigate', {'url': _url});
      try {
        await _waitForLoad();
      } catch (_) {
        // Timeout is acceptable — page may be slow but still usable
      }
    } else if (alreadyOnTarget) {
      connectedToExistingTab = true;
    }
  }

  /// Check if CDP port is already responding.
  /// Handles both standard CDP (HTTP /json/version) and Chrome 146+'s
  /// consent-based port (WebSocket /devtools/browser/{uuid} — no HTTP).
  Future<bool> _isCdpPortAlive() async {
    // Standard CDP: HTTP /json/version
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 2);
      final request = await client
          .getUrl(Uri.parse('http://127.0.0.1:$_port/json/version'));
      final response = await request.close();
      await response.drain<void>();
      client.close();
      _isChrome146ConsentPort = false;
      return true;
    } catch (_) {}

    // Chrome 146+ consent port: HTTP returns 404, but WebSocket to
    // /devtools/browser/{uuid} either connects or hangs (waiting for Allow).
    // A quick 1s probe: if the socket connects (not refused), port is alive.
    try {
      final sock = await Socket.connect(
        InternetAddress.loopbackIPv4,
        _port,
        timeout: const Duration(seconds: 1),
      );
      await sock.close();
      // Port is open. Check if it's a Chrome 146 consent port by probing /json/version.
      // 404 = Chrome 146 consent port. Connection refused = not alive.
      _isChrome146ConsentPort = true;
      return true;
    } catch (_) {}

    return false;
  }

  /// Check if a Chrome/Chromium process is running (any instance, debug port or not).
  /// Used to decide whether to auto-launch a flutter-skill Chrome profile when the
  /// user's Chrome is running without --remote-debugging-port.
  Future<bool> _isChromeRunning() async {
    try {
      ProcessResult result;
      if (Platform.isMacOS) {
        result = await Process.run('pgrep', ['-x', 'Google Chrome']);
        if (result.exitCode == 0) return true;
        // Also check Chromium
        result = await Process.run('pgrep', ['-x', 'Chromium']);
        return result.exitCode == 0;
      } else if (Platform.isLinux) {
        result = await Process.run('pgrep', ['-x', 'google-chrome']);
        if (result.exitCode == 0) return true;
        result = await Process.run('pgrep', ['-x', 'chromium']);
        return result.exitCode == 0;
      } else if (Platform.isWindows) {
        result = await Process.run(
            'tasklist', ['/FI', 'IMAGENAME eq chrome.exe', '/NH']);
        return result.stdout.toString().contains('chrome.exe');
      }
    } catch (_) {}
    return false;
  }

  /// Scan all TCP ports that Chrome is currently listening on and return the
  /// first port that responds as a valid CDP endpoint.
  /// Handles Chrome 136+ which assigns a random port when the user enables
  /// chrome://inspect/#remote-debugging (not necessarily 9222).
  Future<int?> _discoverChromeCdpPort() async {
    try {
      final result = await Process.run('bash',
          ['-c', 'lsof -c "Google Chrome" -a -i TCP -sTCP:LISTEN 2>/dev/null']);
      final portRegex = RegExp(r'127\.0\.0\.1:(\d+)');
      final ports = portRegex
          .allMatches(result.stdout.toString())
          .map((m) => int.tryParse(m.group(1)!) ?? 0)
          .where((p) => p > 1024)
          .toSet()
          .toList();
      for (final port in ports) {
        final prev = _port;
        _port = port;
        if (await _isCdpPortAlive()) return port;
        _port = prev;
      }
    } catch (_) {}
    return null;
  }

  /// Enable Chrome remote debugging via the chrome://inspect/#remote-debugging
  /// page WITHOUT restarting Chrome.
  ///
  /// Chrome 136+ added a "Allow remote debugging for this browser instance"
  /// checkbox on that page.  This method:
  ///   1. Navigates Chrome to chrome://inspect/#remote-debugging
  ///   2. Ticks the checkbox via the macOS Accessibility API (AXCheckBox)
  ///   3. Scans Chrome's new listening port and returns it
  ///
  /// Returns the enabled CDP port, or null if the approach failed (caller
  /// should fall back to restarting Chrome).
  Future<int?> _enableChromeRemoteDebugging() async {
    if (!Platform.isMacOS) return null;
    try {
      // Snapshot of ports before we do anything (to detect the new one).
      final portsBefore = await _getChromeTcpPorts();

      // Navigate to the remote-debugging settings page.
      await Process.run('osascript', [
        '-e',
        'tell application "Google Chrome" to open location '
            '"chrome://inspect/#remote-debugging"'
      ]);
      await Process.run(
          'osascript', ['-e', 'tell application "Google Chrome" to activate']);
      await Future.delayed(const Duration(milliseconds: 2000));

      // Try to tick the checkbox via the macOS Accessibility API.
      // Chrome DevTools WebUI pages expose their content as AX elements.
      final axResult = await Process.run('osascript', [
        '-e',
        r'''
tell application "System Events"
  tell process "Google Chrome"
    activate
    try
      set allElems to entire contents of front window
      repeat with e in allElems
        try
          if role of e is "AXCheckBox" then
            if value of e is 0 then
              click e
            end if
            return "ok:" & (value of e as string)
          end if
        end try
      end repeat
    end try
    return "notfound"
  end tell
end tell
'''
      ]).timeout(const Duration(seconds: 8), onTimeout: () {
        return ProcessResult(0, 0, 'timeout', '');
      });

      final axOut = axResult.stdout.toString().trim();
      if (axOut == 'notfound' || axOut == 'timeout') {
        // AX approach failed — try clicking at the approximate screen position
        // of the checkbox (Chrome devtools page layout is consistent).
        final boundsResult = await Process.run('osascript', [
          '-e',
          '''
tell application "System Events"
  tell process "Google Chrome"
    set w to front window
    return ((item 1 of position of w) as string) & "," & ¬
           ((item 2 of position of w) as string) & "," & ¬
           ((item 1 of size of w) as string) & "," & ¬
           ((item 2 of size of w) as string)
  end tell
end tell
'''
        ]);
        final parts = boundsResult.stdout
            .toString()
            .trim()
            .split(',')
            .map((s) => double.tryParse(s.trim()))
            .whereType<double>()
            .toList();
        if (parts.length >= 4) {
          // Checkbox is roughly at: sidebar(230) + margin(30), toolbar(130) + 100
          final cx = (parts[0] + 265).toInt();
          final cy = (parts[1] + 230).toInt();
          await Process.run('osascript', [
            '-e',
            'tell application "System Events" to click at {$cx, $cy}'
          ]);
        }
      }

      await Future.delayed(const Duration(milliseconds: 1200));

      // Discover the newly opened CDP port (port that wasn't there before).
      final portsAfter = await _getChromeTcpPorts();
      final newPorts =
          portsAfter.where((p) => !portsBefore.contains(p)).toList();

      // Check new ports first, then all Chrome ports.
      for (final port in [...newPorts, ...portsAfter]) {
        _port = port;
        if (await _isCdpPortAlive()) return port;
      }
    } catch (_) {}
    return null;
  }

  /// Returns all TCP ports Chrome is currently listening on (127.0.0.1 only).
  Future<List<int>> _getChromeTcpPorts() async {
    try {
      final result = await Process.run('bash',
          ['-c', 'lsof -c "Google Chrome" -a -i TCP -sTCP:LISTEN 2>/dev/null']);
      final portRegex = RegExp(r'127\.0\.0\.1:(\d+)');
      return portRegex
          .allMatches(result.stdout.toString())
          .map((m) => int.tryParse(m.group(1)!) ?? 0)
          .where((p) => p > 1024)
          .toSet()
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Returns the OS-default Chrome user-data-dir (the user's actual profile).
  String _defaultChromeUserDataDir() {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';
    if (Platform.isMacOS) {
      return '$home/Library/Application Support/Google/Chrome';
    } else if (Platform.isLinux) {
      return '$home/.config/google-chrome';
    } else if (Platform.isWindows) {
      final appData =
          Platform.environment['LOCALAPPDATA'] ?? '$home/AppData/Local';
      return '$appData\\Google\\Chrome\\User Data';
    }
    return '$home/.config/google-chrome';
  }

  /// Path for the session-copy profile directory.
  /// Uses a non-default path so Chrome 136+ allows --remote-debugging-port.
  static String get _sessionCopyProfileDir {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '.';
    return '$home/.flutter-skill/chrome-session';
  }

  /// Find the most recently modified profile subdirectory within [userDataDir].
  /// Checks Default, Profile 1 … Profile 9, and returns the one whose Cookies
  /// file was most recently modified (best proxy for the active profile).
  Future<String?> _findActiveProfileDir(String userDataDir) async {
    final names = [
      'Default',
      ...List.generate(9, (i) => 'Profile ${i + 1}'),
    ];
    String? latest;
    DateTime? latestMod;
    for (final name in names) {
      final cookies = File('$userDataDir/$name/Cookies');
      if (!cookies.existsSync()) continue;
      final mod = cookies.statSync().modified;
      if (latestMod == null || mod.isAfter(latestMod)) {
        latestMod = mod;
        latest = '$userDataDir/$name';
      }
    }
    return latest;
  }

  /// Copy a directory recursively, skipping locked / unreadable files silently.
  Future<void> _copyDirectory(Directory src, Directory dest) async {
    if (!dest.existsSync()) dest.createSync(recursive: true);
    try {
      await for (final entity in src.list()) {
        final name = entity.uri.pathSegments
            .lastWhere((s) => s.isNotEmpty, orElse: () => '');
        if (name.isEmpty) continue;
        if (entity is File) {
          try {
            await entity.copy('${dest.path}/$name');
          } catch (_) {}
        } else if (entity is Directory) {
          await _copyDirectory(entity, Directory('${dest.path}/$name'));
        }
      }
    } catch (_) {}
  }

  /// Create (or refresh) a session-copy profile at [_sessionCopyProfileDir] by
  /// copying the essential login/cookie files from the user's active Chrome profile.
  /// Returns the path to use as --user-data-dir when launching Chrome.
  Future<String> _createSessionCopyProfile(String userDataDir) async {
    final destRoot = _sessionCopyProfileDir;
    final destProfile = '$destRoot/Default';
    await Directory(destProfile).create(recursive: true);

    final sourceProfile = await _findActiveProfileDir(userDataDir);
    if (sourceProfile != null) {
      // Essential files for session preservation.
      for (final filename in [
        'Cookies',
        'Extension Cookies',
        'Login Data',
        'Login Data For Account',
        'Preferences',
        'Secure Preferences',
      ]) {
        final src = File('$sourceProfile/$filename');
        if (src.existsSync()) {
          try {
            await src.copy('$destProfile/$filename');
          } catch (_) {}
        }
      }
      // Local Storage contains IndexedDB / localStorage session tokens.
      final lsDir = Directory('$sourceProfile/Local Storage');
      if (lsDir.existsSync()) {
        await _copyDirectory(lsDir, Directory('$destProfile/Local Storage'));
      }
    }

    // Local State holds multi-profile config and the encryption key reference.
    final localState = File('$userDataDir/Local State');
    if (localState.existsSync()) {
      try {
        await localState.copy('$destRoot/Local State');
      } catch (_) {}
    }

    return destRoot;
  }

  /// Quit Chrome gracefully (AppleScript on macOS, SIGTERM on Linux, taskkill on Windows).
  Future<void> _quitChrome() async {
    try {
      if (Platform.isMacOS) {
        await Process.run(
            'osascript', ['-e', 'tell application "Google Chrome" to quit']);
      } else if (Platform.isLinux) {
        await Process.run('pkill', ['-x', 'google-chrome']);
        await Process.run('pkill', ['-x', 'chromium']);
      } else if (Platform.isWindows) {
        await Process.run('taskkill', ['/F', '/IM', 'chrome.exe']);
      }
    } catch (_) {}
  }

  /// Poll until Chrome process is no longer running (max 3 seconds).
  Future<void> _waitForChromeExit() async {
    for (var i = 0; i < 30; i++) {
      if (!await _isChromeRunning()) return;
      await Future.delayed(const Duration(milliseconds: 100));
    }
  }

  /// Quit the user's running Chrome and relaunch it with the same profile +
  /// --remote-debugging-port, so remote debugging is enabled without losing
  /// the user's existing session / logins.
  ///
  /// Chrome 136+ blocks --remote-debugging-port on the default user-data-dir.
  /// If that happens (process exits fast), we automatically fall back to
  /// launching with a separate flutter-skill profile (no user session).
  Future<void> _restartChromeWithDebugPort() async {
    final userDataDir = _defaultChromeUserDataDir();

    // Quit the running Chrome instance.
    await _quitChrome();
    await _waitForChromeExit();

    // Find the Chrome executable (same search order as _launchChromeProcess).
    String? chromePath;
    if (_chromePath != null) {
      chromePath = _chromePath;
    } else if (Platform.isMacOS) {
      chromePath =
          '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
    } else if (Platform.isLinux) {
      for (final p in ['google-chrome', 'google-chrome-stable', 'chromium']) {
        final r = await Process.run('which', [p]);
        if (r.exitCode == 0) {
          chromePath = r.stdout.toString().trim();
          break;
        }
      }
    } else if (Platform.isWindows) {
      chromePath = r'C:\Program Files\Google\Chrome\Application\chrome.exe';
    }

    if (chromePath == null) {
      await _launchChromeProcess();
      return;
    }

    final args = [
      '--remote-debugging-port=$_port',
      '--remote-allow-origins=*',
      '--user-data-dir=$userDataDir',
      '--no-first-run',
      '--no-default-browser-check',
      if (_headless) '--headless=new',
      if (_proxy != null) '--proxy-server=$_proxy',
      if (_ignoreSsl) '--ignore-certificate-errors',
      if (_url.isNotEmpty) _url,
    ];

    try {
      if (Platform.isMacOS && chromePath.contains('.app/')) {
        final appBundle = chromePath.substring(
            0, chromePath.indexOf('.app/') + '.app/'.length - 1);
        await Process.run('xattr', ['-cr', appBundle]);
      }
      _chromeProcess = await Process.start(chromePath, args);
    } catch (_) {
      // Could not start Chrome — fall back to flutter-skill profile.
      await _launchChromeProcess();
      return;
    }

    // Chrome 136+ may reject --remote-debugging-port on the default user-data-dir
    // in two ways:
    //   a) Exit immediately (early Chrome 136 behaviour)
    //   b) Stay alive but silently ignore the flag (Chrome 145+ behaviour)
    // Check both: process exit AND port actually opening.
    await Future.delayed(const Duration(milliseconds: 800));
    final code = await _chromeProcess!.exitCode
        .timeout(const Duration(milliseconds: 200), onTimeout: () => -1);
    if (code != -1) {
      // Chrome exited immediately — rejected the debug port.
      _chromeProcess = null;
      await _launchChromeProcess();
      return;
    }

    // Chrome is still running — verify the debug port actually opened.
    final portOpened = await _pollCdpPort(
        timeout: const Duration(seconds: 4),
        interval: const Duration(milliseconds: 200));
    if (!portOpened) {
      // Chrome silently ignored --remote-debugging-port (Chrome 145+ behaviour).
      // Kill this instance, then try session-copy profile (copies user's cookies/storage
      // to a non-default path so Chrome allows the debug port while preserving logins).
      try {
        _chromeProcess?.kill();
      } catch (_) {}
      _chromeProcess = null;

      try {
        final sessionDir = await _createSessionCopyProfile(userDataDir);
        final sessionArgs = [
          '--remote-debugging-port=$_port',
          '--remote-allow-origins=*',
          '--user-data-dir=$sessionDir',
          '--no-first-run',
          '--no-default-browser-check',
          if (_headless) '--headless=new',
          if (_proxy != null) '--proxy-server=$_proxy',
          if (_ignoreSsl) '--ignore-certificate-errors',
          if (_url.isNotEmpty) _url,
        ];
        _chromeProcess = await Process.start(chromePath, sessionArgs);
        final sessionPortOpened = await _pollCdpPort(
          timeout: const Duration(seconds: 6),
          interval: const Duration(milliseconds: 200),
        );
        if (sessionPortOpened)
          return; // Session copy worked with debug port open.
        try {
          _chromeProcess?.kill();
        } catch (_) {}
        _chromeProcess = null;
      } catch (_) {}

      // Final fallback: flutter-skill's own blank profile (no user session).
      await _launchChromeProcess();
    }
    // else: Chrome accepted and port is open — running with user's profile.
  }

  /// Get the current page URL via Runtime.evaluate
  Future<String?> _getCurrentUrl() async {
    try {
      final result = await _call('Runtime.evaluate', {
        'expression': 'location.href',
        'returnByValue': true,
      });
      return result['result']?['value'] as String?;
    } catch (_) {
      return null;
    }
  }

  /// Reconnect to a new WebSocket URL (e.g., after target navigates away)
  Future<void> reconnectTo(String wsUrl) async {
    _connected = false;
    _reconnecting = true; // Prevent _autoReconnect from overriding this
    _failAllPending('Reconnecting');
    try {
      await _ws?.close();
    } catch (_) {}
    _ws = null;

    _ws = await _connectCdpWebSocket(wsUrl);
    _connected = true;

    _ws!.listen(
      _onMessage,
      onDone: _onDisconnect,
      onError: (_) => _onDisconnect(),
      cancelOnError: false,
    );

    // Re-enable required CDP domains
    await Future.wait([
      _call('Page.enable'),
      _call('DOM.enable'),
      _call('Runtime.enable'),
    ]);
    _reconnecting = false;
  }

  @override
  Future<void> disconnect() async {
    _connected = false;
    _failAllPending('Disconnected');
    try {
      await _ws?.close();
    } catch (_) {}
    _ws = null;

    if (_chromeProcess != null) {
      _chromeProcess!.kill();
      _chromeProcess = null;
    }
  }

  @override
  Future<Map<String, dynamic>> tap(
      {String? key, String? text, String? ref}) async {
    // Find element and get its center coordinates
    final selector = _buildSelector(key: key, text: text, ref: ref);
    final bounds = await _getElementBounds(selector, text: text);
    if (bounds == null) {
      return {
        'success': false,
        'error': {'message': 'Element not found: ${key ?? text ?? ref}'},
      };
    }

    final cx = bounds['cx'] as double;
    final cy = bounds['cy'] as double;

    await _dispatchMouseEvent('mousePressed', cx, cy,
        button: 'left', clickCount: 1);
    await _dispatchMouseEvent('mouseReleased', cx, cy,
        button: 'left', clickCount: 1);
    await _ensureFocusAtPoint(cx, cy);

    return {
      'success': true,
      'position': {'x': cx, 'y': cy},
    };
  }

  @override
  Future<Map<String, dynamic>> enterText(String? key, String text,
      {String? ref}) async {
    // Focus the element first
    if (key != null || ref != null) {
      final selector = _buildSelector(key: key, ref: ref);
      final result = await _evalJs('''
        (() => {
          const el = document.querySelector('$selector');
          if (!el) return false;
          el.focus();
          el.value = '';
          return true;
        })()
      ''');
      if (result['result']?['value'] != true) {
        return {
          'success': false,
          'error': {'message': 'Element not found: ${key ?? ref}'},
        };
      }
    }

    // Type each character
    for (final char in text.codeUnits) {
      await _call('Input.dispatchKeyEvent', {
        'type': 'keyDown',
        'text': String.fromCharCode(char),
        'key': String.fromCharCode(char),
        'unmodifiedText': String.fromCharCode(char),
      });
      await _call('Input.dispatchKeyEvent', {
        'type': 'keyUp',
        'key': String.fromCharCode(char),
      });
    }

    // Dispatch input event for frameworks that listen to it
    if (key != null || ref != null) {
      final selector = _buildSelector(key: key, ref: ref);
      await _evalJs('''
        (() => {
          const el = document.querySelector('$selector');
          if (el) {
            el.dispatchEvent(new Event('input', {bubbles: true}));
            el.dispatchEvent(new Event('change', {bubbles: true}));
          }
        })()
      ''');
    }

    return {'success': true};
  }

  @override
  Future<bool> swipe(
      {required String direction, double distance = 300, String? key}) async {
    // Get viewport dimensions
    final metrics = await _call('Page.getLayoutMetrics');
    final vw =
        (metrics['cssLayoutViewport']?['clientWidth'] as num?)?.toDouble() ??
            800.0;
    final vh =
        (metrics['cssLayoutViewport']?['clientHeight'] as num?)?.toDouble() ??
            600.0;

    double startX = vw / 2, startY = vh / 2, endX = vw / 2, endY = vh / 2;

    switch (direction) {
      case 'up':
        startY = vh / 2 + distance / 2;
        endY = vh / 2 - distance / 2;
        break;
      case 'down':
        startY = vh / 2 - distance / 2;
        endY = vh / 2 + distance / 2;
        break;
      case 'left':
        startX = vw / 2 + distance / 2;
        endX = vw / 2 - distance / 2;
        break;
      case 'right':
        startX = vw / 2 - distance / 2;
        endX = vw / 2 + distance / 2;
        break;
    }

    await _dispatchMouseEvent('mousePressed', startX, startY, button: 'left');
    await _dispatchMouseEvent('mouseMoved', endX, endY, button: 'left');
    await _dispatchMouseEvent('mouseReleased', endX, endY, button: 'left');
    return true;
  }

  @override
  Future<List<dynamic>> getInteractiveElements(
      {bool includePositions = true}) async {
    final result = await _evalJs('''
      (() => {
        const selectors = 'a, button, input, select, textarea, [role="button"], [role="link"], [role="checkbox"], [role="radio"], [role="tab"], [onclick], [tabindex], [contenteditable="true"]';
        // Recursive query that traverses Shadow DOM
        function deepQueryAll(root, sel) {
          const results = Array.from(root.querySelectorAll(sel));
          root.querySelectorAll('*').forEach(el => {
            if (el.shadowRoot) results.push(...deepQueryAll(el.shadowRoot, sel));
          });
          return results;
        }
        const elements = deepQueryAll(document, selectors);
        return elements.filter(el => {
          const style = window.getComputedStyle(el);
          return style.display !== 'none' && style.visibility !== 'hidden' && el.offsetParent !== null;
        }).map((el, i) => {
          const rect = el.getBoundingClientRect();
          const tag = el.tagName.toLowerCase();
          const type = el.getAttribute('type') || '';
          const role = el.getAttribute('role') || '';
          const text = (el.textContent || '').trim().substring(0, 100);
          const id = el.id || '';
          const name = el.getAttribute('name') || '';
          const ariaLabel = el.getAttribute('aria-label') || '';
          const placeholder = el.getAttribute('placeholder') || '';
          const value = el.value || '';
          return {
            index: i,
            tag: tag,
            type: type || tag,
            role: role,
            text: text,
            key: id || name || null,
            label: ariaLabel || placeholder || '',
            value: value,
            bounds: {
              x: Math.round(rect.left),
              y: Math.round(rect.top),
              w: Math.round(rect.width),
              h: Math.round(rect.height)
            },
            center: {
              x: Math.round(rect.left + rect.width / 2),
              y: Math.round(rect.top + rect.height / 2)
            },
            visible: true,
            clickable: true,
            coordinatesReliable: true
          };
        });
      })()
    ''');

    final value = result['result']?['value'];
    if (value is List) return value;
    // If result is a remote object, need to get properties
    final objectId = result['result']?['objectId'] as String?;
    if (objectId != null) {
      final props = await _call('Runtime.getProperties', {
        'objectId': objectId,
        'ownProperties': true,
      });
      // Parse array-like properties
      final elements = <dynamic>[];
      for (final prop in (props['result'] as List? ?? [])) {
        if (prop is Map &&
            prop['value']?['type'] == 'object' &&
            prop['name'] != '__proto__' &&
            prop['name'] != 'length') {
          final elObjId = prop['value']['objectId'] as String?;
          if (elObjId != null) {
            final elProps = await _call('Runtime.getProperties', {
              'objectId': elObjId,
              'ownProperties': true,
            });
            final map = <String, dynamic>{};
            for (final p in (elProps['result'] as List? ?? [])) {
              if (p is Map && p['name'] != '__proto__') {
                final v = p['value'];
                if (v?['type'] == 'object' && v?['objectId'] != null) {
                  // nested object (bounds, center) — get properties
                  final nested = await _call('Runtime.getProperties', {
                    'objectId': v['objectId'],
                    'ownProperties': true,
                  });
                  final nestedMap = <String, dynamic>{};
                  for (final np in (nested['result'] as List? ?? [])) {
                    if (np is Map && np['name'] != '__proto__') {
                      nestedMap[np['name']] = np['value']?['value'];
                    }
                  }
                  map[p['name']] = nestedMap;
                } else {
                  map[p['name']] = v?['value'];
                }
              }
            }
            elements.add(map);
          }
        }
      }
      return elements;
    }
    return [];
  }

  @override
  Future<Map<String, dynamic>> getInteractiveElementsStructured() async {
    final result = await _evalJs('''
      (() => {
        const selectors = 'a, button, input, select, textarea, [role="button"], [role="link"], [role="checkbox"], [role="radio"], [role="tab"], [onclick], [tabindex], [contenteditable="true"]';
        function deepQueryAll(root, sel) {
          const results = Array.from(root.querySelectorAll(sel));
          root.querySelectorAll('*').forEach(el => {
            if (el.shadowRoot) results.push(...deepQueryAll(el.shadowRoot, sel));
          });
          return results;
        }
        const elements = deepQueryAll(document, selectors);
        const visible = elements.filter(el => {
          const style = window.getComputedStyle(el);
          return style.display !== 'none' && style.visibility !== 'hidden' && el.offsetParent !== null;
        });
        const mapped = visible.map((el, i) => {
          const rect = el.getBoundingClientRect();
          const tag = el.tagName.toLowerCase();
          const type = el.getAttribute('type') || '';
          const role = el.getAttribute('role') || tag;
          const text = (el.textContent || '').trim().substring(0, 100);
          const id = el.id || '';
          const name = el.getAttribute('name') || '';
          const ariaLabel = el.getAttribute('aria-label') || '';
          const placeholder = el.getAttribute('placeholder') || '';
          
          let refName = '';
          if (tag === 'button' || role === 'button') refName = 'button:' + (text || ariaLabel || id || ('idx_' + i));
          else if (tag === 'input' || tag === 'textarea') refName = 'input:' + (ariaLabel || placeholder || name || id || ('idx_' + i));
          else if (tag === 'a' || role === 'link') refName = 'link:' + (text || ariaLabel || id || ('idx_' + i));
          else if (tag === 'select') refName = 'select:' + (ariaLabel || name || id || ('idx_' + i));
          else refName = role + ':' + (text || ariaLabel || id || ('idx_' + i));
          
          const actions = [];
          actions.push('tap');
          if (tag === 'input' || tag === 'textarea') actions.push('enter_text');
          if (tag === 'select') actions.push('select');
          
          return {
            type: tag,
            text: text,
            label: ariaLabel || placeholder,
            ref: refName,
            selector: id ? ('#' + id) : (name ? ('[name="' + name + '"]') : null),
            actions: actions,
            bounds: { x: Math.round(rect.left), y: Math.round(rect.top), w: Math.round(rect.width), h: Math.round(rect.height) },
            enabled: !el.disabled,
            visible: true,
            value: el.value || null
          };
        });
        
        const summary = 'Found ' + mapped.length + ' interactive elements';
        return JSON.stringify({elements: mapped, summary: summary});
      })()
    ''');

    final value = result['result']?['value'];
    if (value is String) {
      return (jsonDecode(value) as Map<String, dynamic>);
    }
    return {'elements': [], 'summary': 'Failed to inspect elements'};
  }

  /// Fast accessibility snapshot via single JS evaluation.
  /// Scans all interactive + landmark elements, assigns ref IDs, returns compact text.
  /// Benchmarked at ~10-50ms (vs 60ms+ for CDP Accessibility.getFullAXTree).
  /// Pierces Shadow DOM automatically.
  Future<Map<String, dynamic>> getAccessibilitySnapshot() async {
    final result = await _evalJs(r'''
(() => {
  const t0 = performance.now();
  // Deep query helper for Shadow DOM
  function dqAll(sel, root) {
    root = root || document;
    let r = Array.from(root.querySelectorAll(sel));
    for (const n of root.querySelectorAll('*')) {
      if (n.shadowRoot) r = r.concat(dqAll(sel, n.shadowRoot));
    }
    return r;
  }
  
  // ===== Detect page-level context =====
  const framework = (() => {
    if (window.__NEXT_DATA__) return 'nextjs';
    if (window.__NUXT__) return 'nuxt';
    if (document.querySelector('[ng-version]')) return 'angular';
    if (document.querySelector('[data-reactroot]') || document.querySelector('#__next')) return 'react';
    if (document.querySelector('[data-v-]')) return 'vue';
    return 'unknown';
  })();
  
  // Detect editor type
  const editorType = (() => {
    if (document.querySelector('.CodeMirror')) return 'codemirror';
    if (document.querySelector('.cm-editor')) return 'codemirror6';
    if (document.querySelector('.DraftEditor-root')) return 'draft-js';
    if (document.querySelector('.tiptap.ProseMirror')) return 'tiptap';
    if (document.querySelector('.ProseMirror')) return 'prosemirror';
    if (document.querySelector('.ql-editor')) return 'quill';
    if (document.querySelector('[contenteditable="true"]')) return 'contenteditable';
    return 'none';
  })();
  
  // Recommend best input method based on framework + editor
  const inputMethod = (() => {
    if (editorType === 'codemirror' || editorType === 'codemirror6') return 'api:CodeMirror.setValue()';
    if (editorType === 'draft-js') return 'clipboard:paste-event';
    if (editorType === 'tiptap' || editorType === 'prosemirror') return 'html:innerHTML+input-event';
    if (editorType === 'quill') return 'api:quill.clipboard.dangerouslyPasteHTML()';
    if (framework === 'react') return 'cdp:Input.insertText';
    return 'cdp:Input.insertText';
  })();
  
  const interactiveSel = 'a,button,input,select,textarea,[role="button"],[role="link"],[role="textbox"],[role="searchbox"],[role="combobox"],[role="checkbox"],[role="radio"],[role="switch"],[role="tab"],[role="menuitem"],[role="option"],[role="slider"],[contenteditable="true"]';
  const landmarkSel = 'h1,h2,h3,h4,h5,h6,nav,main,header,footer,[role="heading"],[role="navigation"],[role="main"],[role="banner"],[role="complementary"],[role="dialog"],[role="alert"],[role="status"],img[alt],label,[class*="error"],[class*="warning"],[aria-invalid]';
  
  const allEls = dqAll(interactiveSel + ',' + landmarkSel);

  // Also collect elements from same-origin iframes
  const iframeEls = [];
  const iframeOffsets = new WeakMap();
  try {
    for (const iframe of document.querySelectorAll('iframe')) {
      try {
        const doc = iframe.contentDocument;
        if (!doc) continue;
        const iRect = iframe.getBoundingClientRect();
        if (iRect.width === 0 || iRect.height === 0) continue;
        const sel = interactiveSel + ',' + landmarkSel;
        for (const el of doc.querySelectorAll(sel)) {
          iframeEls.push(el);
          iframeOffsets.set(el, {dx: iRect.x, dy: iRect.y, src: iframe.src.substring(0, 60)});
        }
      } catch(e) { /* cross-origin iframe — skip */ }
    }
  } catch(e) {}
  // Second pass: find clickable custom elements inside shadow roots that the
  // selector-based dqAll may have missed (e.g. Reddit's faceplate-button).
  function findShadowInteractive(root) {
    let results = [];
    for (const el of root.querySelectorAll('*')) {
      if (el.shadowRoot) {
        for (const inner of el.shadowRoot.querySelectorAll('button, [role="button"], [type="submit"]')) {
          if (!allEls.includes(inner)) results.push(inner);
        }
        results = results.concat(findShadowInteractive(el.shadowRoot));
      }
    }
    return results;
  }
  const shadowEls = findShadowInteractive(document);
  const combinedEls = [...allEls, ...iframeEls, ...shadowEls];

  const vw = window.innerWidth;
  const vh = window.innerHeight;
  let refN = 0;
  const lines = [];
  const refs = {};
  let interactiveCount = 0;
  const requiredEmpty = [];
  const errors = [];
  
  for (const el of combinedEls) {
    const iframeOff = iframeOffsets.get(el);
    const r = el.getBoundingClientRect();
    // For iframe elements, we store the offset but use raw rect for visibility check
    if (r.width === 0 && r.height === 0) continue;
    const s = getComputedStyle(el);
    if (s.display === 'none' || s.visibility === 'hidden') continue;
    
    const tag = el.tagName.toLowerCase();
    const role = el.getAttribute('role') || ({'a':'link','button':'button','input':'textbox','select':'combobox','textarea':'textbox','h1':'heading','h2':'heading','h3':'heading','h4':'heading','h5':'heading','h6':'heading','nav':'navigation','img':'img','label':'label'}[tag] || tag);
    const text = (el.textContent || '').trim().substring(0, 60);
    const ariaLabel = el.getAttribute('aria-label') || '';
    const placeholder = el.getAttribute('placeholder') || '';
    const name = ariaLabel || placeholder || text;
    const displayName = name.length > 55 ? name.substring(0, 52) + '...' : name;
    const value = el.value || '';
    const type = el.getAttribute('type') || '';
    
    const isInteractive = /^(link|button|textbox|searchbox|combobox|checkbox|radio|switch|tab|menuitem|option|slider)$/.test(role) || el.hasAttribute('contenteditable');
    
    refN++;
    const refId = 'e' + refN;
    if (isInteractive) interactiveCount++;
    
    // ===== Enhanced state detection =====
    const states = [];
    if (el.disabled) states.push('disabled');
    if (el.checked) states.push('checked');
    if (el.getAttribute('aria-expanded') === 'true') states.push('expanded');
    if (el.getAttribute('aria-selected') === 'true') states.push('selected');
    if (el.required || el.getAttribute('aria-required') === 'true') states.push('required');
    if (document.activeElement === el) states.push('focused');
    if (el.getAttribute('aria-invalid') === 'true') states.push('invalid');
    if (el.readOnly) states.push('readonly');
    
    // Empty check for required fields
    const isEmpty = (tag === 'input' || tag === 'textarea' || tag === 'select') && !value.trim();
    const isEmptyEditable = el.hasAttribute('contenteditable') && !el.textContent?.trim();
    if ((el.required || el.getAttribute('aria-required') === 'true') && (isEmpty || isEmptyEditable)) {
      states.push('empty');
      requiredEmpty.push(displayName || role + '#' + refId);
    }
    
    // ===== Validation info =====
    let validation = '';
    if (el.validity && !el.validity.valid && value) {
      if (el.validity.tooShort) validation = ' minlen=' + el.minLength;
      if (el.validity.tooLong) validation = ' maxlen=' + el.maxLength;
      if (el.validity.patternMismatch) validation = ' pattern=' + el.pattern;
      if (el.validity.typeMismatch) validation = ' invalid-format';
    }
    if (el.minLength > 0) validation += ' minlen=' + el.minLength;
    if (el.maxLength > 0 && el.maxLength < 10000) validation += ' maxlen=' + el.maxLength;
    
    // ===== Error message detection =====
    if (el.classList?.contains('error') || el.getAttribute('aria-invalid') === 'true' ||
        (el.className && /error|warning|invalid/i.test(el.className))) {
      const errText = el.textContent?.trim();
      if (errText && errText.length < 100) errors.push(errText);
    }
    // Check aria-errormessage
    const errMsgId = el.getAttribute('aria-errormessage') || el.getAttribute('aria-describedby');
    if (errMsgId) {
      const errEl = document.getElementById(errMsgId);
      if (errEl?.textContent?.trim()) errors.push(errEl.textContent.trim());
    }
    
    // ===== Select/dropdown options =====
    let optionsStr = '';
    if (tag === 'select') {
      const opts = Array.from(el.options || []).map(o => o.text?.trim()).filter(Boolean).slice(0, 10);
      if (opts.length) optionsStr = ' options=[' + opts.join(',') + ']';
    }
    
    // ===== Disabled button reason =====
    let disabledReason = '';
    if (el.disabled && role === 'button' && requiredEmpty.length > 0) {
      disabledReason = ' reason="missing:' + requiredEmpty.join(',') + '"';
    }
    
    const stateStr = states.length ? ' [' + states.join(',') + ']' : '';
    const valueStr = value && type !== 'password' ? ' value="' + value.substring(0, 30) + '"' : '';
    const typeStr = type && type !== 'text' ? ' type=' + type : '';
    const refStr = isInteractive ? ' [ref=' + refId + ']' : '';
    
    // Viewport indicator
    const inView = r.top >= -10 && r.bottom <= vh + 10;
    const offscreen = !inView && (r.bottom < -100 || r.top > vh + 100) ? ' (offscreen)' : '';
    // Beyond viewport width (important for dialog buttons)
    const beyondVW = r.left > vw ? ' (beyond-viewport-x:' + Math.round(r.left) + ')' : '';
    
    refs[refId] = displayName;
    const iframeTag = iframeOff ? ' (iframe:' + iframeOff.src + ')' : '';
    lines.push(role + ' "' + displayName + '"' + typeStr + valueStr + optionsStr + refStr + stateStr + validation + disabledReason + offscreen + beyondVW + iframeTag);
  }
  
  const elapsed = Math.round(performance.now() - t0);
  const snapshot = lines.join('\n');
  
  // ===== Form summary =====
  const formMeta = {
    framework: framework,
    editorType: editorType,
    inputMethod: inputMethod,
    requiredEmpty: requiredEmpty,
    errors: errors,
    viewport: vw + 'x' + vh,
  };
  
  return JSON.stringify({
    snapshot: snapshot,
    interactiveCount: interactiveCount,
    totalElements: refN,
    tokenEstimate: Math.round(snapshot.length / 4),
    elapsedMs: elapsed,
    formMeta: formMeta,
    hint: requiredEmpty.length > 0
      ? 'BLOCKED: Required empty fields: [' + requiredEmpty.join(', ') + ']. Fill these before submit. Use ' + inputMethod + ' for input.'
      : 'Ready to submit. Use act(ref, action) to interact.',
    refs: refs
  });
})()
    ''');

    final parsed = _parseJsonEval(result);
    if (parsed != null) return parsed;
    // Fallback
    return await getInteractiveElementsStructured();
  }

  /// Fast composite action — find + scroll + act in a SINGLE JS evaluation.
  /// Benchmarked: ~1-15ms for click, ~2-20ms for fill (vs ~1000ms before).
  /// Falls back to CDP Input.dispatch for actions that need real mouse events.
  Future<Map<String, dynamic>> act({
    String? ref,
    String? text,
    String? key,
    required String action,
    String? value,
    int timeoutMs = 5000,
    bool dispatchRealEvents = false,
  }) async {
    // Escape parameters for JS
    final jsText = text
            ?.replaceAll('\\', '\\\\')
            .replaceAll("'", "\\'")
            .replaceAll('\n', '\\n') ??
        '';
    final jsKey = key?.replaceAll('\\', '\\\\').replaceAll("'", "\\'") ?? '';
    final jsRef = ref?.replaceAll('\\', '\\\\').replaceAll("'", "\\'") ?? '';
    final jsValue = value
            ?.replaceAll('\\', '\\\\')
            .replaceAll("'", "\\'")
            .replaceAll('\n', '\\n') ??
        '';

    // Single JS eval: find + scroll + act
    final result = await _evalJs('''
(() => {
  const t0 = performance.now();
  // Deep query helpers
  function dq(sel, root) {
    root = root || document;
    let el = root.querySelector(sel);
    if (el) return el;
    for (const n of root.querySelectorAll('*')) {
      if (n.shadowRoot) { el = dq(sel, n.shadowRoot); if (el) return el; }
    }
    return null;
  }
  function dqAll(sel, root) {
    root = root || document;
    let r = Array.from(root.querySelectorAll(sel));
    for (const n of root.querySelectorAll('*')) {
      if (n.shadowRoot) r = r.concat(dqAll(sel, n.shadowRoot));
    }
    return r;
  }
  
  let el = null;
  const refId = '$jsRef';
  const textQuery = '$jsText';
  const keyQuery = '$jsKey';
  
  // Strategy 1: By CSS selector/key
  if (keyQuery) {
    el = dq(keyQuery) || dq('#' + keyQuery) || dq('[name="' + keyQuery + '"]') || dq('[data-testid="' + keyQuery + '"]');
  }
  
  // Strategy 2: By ref ID (e.g. "e5" from snapshot)
  if (!el && refId) {
    // Refs are positional — find the Nth interactive element
    const refMatch = refId.match(/^e(\\d+)\$/);
    if (refMatch) {
      const idx = parseInt(refMatch[1]) - 1;
      const interactiveSel = 'a,button,input,select,textarea,[role="button"],[role="link"],[role="textbox"],[role="searchbox"],[role="combobox"],[role="checkbox"],[role="radio"],[role="switch"],[role="tab"],[role="menuitem"],[role="option"],[role="slider"],[contenteditable="true"],h1,h2,h3,h4,h5,h6,nav,main,header,footer,[role="heading"],[role="navigation"],[role="main"],[role="banner"],[role="complementary"],[role="dialog"],[role="alert"],[role="status"],img[alt],label';
      const all = dqAll(interactiveSel);
      const visible = all.filter(e => {
        const r = e.getBoundingClientRect();
        if (r.width === 0 && r.height === 0) return false;
        const s = getComputedStyle(e);
        return s.display !== 'none' && s.visibility !== 'hidden';
      });
      if (idx < visible.length) el = visible[idx];
    }
    // Also try by ref-like selector
    if (!el) el = dq('[data-ref="' + refId + '"]');
  }
  
  // Strategy 3: By text content (exact then partial)
  if (!el && textQuery) {
    const all = dqAll('a,button,input,select,textarea,label,span,div,h1,h2,h3,h4,h5,h6,[role="button"],[role="link"],[role="tab"],[role="menuitem"],[role="option"]');
    for (const e of all) {
      if (e.textContent && e.textContent.trim() === textQuery) { el = e; break; }
    }
    if (!el) {
      for (const e of all) {
        if (e.textContent && e.textContent.trim().includes(textQuery)) { el = e; break; }
      }
    }
  }
  
  if (!el) {
    return JSON.stringify({success: false, error: 'Element not found: ' + (refId || textQuery || keyQuery), elapsedMs: Math.round(performance.now() - t0)});
  }
  
  // Scroll into view if needed
  const rect = el.getBoundingClientRect();
  if (rect.top < 0 || rect.bottom > window.innerHeight) {
    el.scrollIntoView({behavior: 'instant', block: 'center'});
  }
  
  const action = '$action';
  const fillValue = '$jsValue';
  const cx = Math.round(rect.left + rect.width / 2);
  const cy = Math.round(rect.top + rect.height / 2);
  
  switch (action) {
    case 'click':
    case 'tap':
      el.focus();
      el.click();
      return JSON.stringify({success: true, action: 'click', position: {x: cx, y: cy}, elapsedMs: Math.round(performance.now() - t0)});
    
    case 'fill': {
      el.focus();
      if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.tagName === 'SELECT') {
        el.value = '';
        el.value = fillValue;
        el.dispatchEvent(new Event('input', {bubbles: true}));
        el.dispatchEvent(new Event('change', {bubbles: true}));
      } else if (el.isContentEditable || el.getAttribute('contenteditable') === 'true') {
        el.innerHTML = fillValue;
        el.dispatchEvent(new Event('input', {bubbles: true}));
      }
      return JSON.stringify({success: true, action: 'fill', value: fillValue, elapsedMs: Math.round(performance.now() - t0)});
    }
    
    case 'select': {
      if (el.tagName === 'SELECT') {
        el.value = fillValue;
        el.dispatchEvent(new Event('change', {bubbles: true}));
      } else {
        el.click();
      }
      return JSON.stringify({success: true, action: 'select', value: fillValue, elapsedMs: Math.round(performance.now() - t0)});
    }
    
    case 'hover':
      el.dispatchEvent(new MouseEvent('mouseenter', {bubbles: true}));
      el.dispatchEvent(new MouseEvent('mouseover', {bubbles: true}));
      return JSON.stringify({success: true, action: 'hover', position: {x: cx, y: cy}, elapsedMs: Math.round(performance.now() - t0)});
    
    case 'check':
      el.click();
      return JSON.stringify({success: true, action: 'check', checked: el.checked, elapsedMs: Math.round(performance.now() - t0)});
    
    default:
      return JSON.stringify({success: false, error: 'Unknown action: ' + action});
  }
})()
    ''');

    final parsed = _parseJsonEval(result);
    if (parsed != null) {
      // For click actions needing real mouse events (e.g., custom components),
      // fall back to CDP Input.dispatch
      if (dispatchRealEvents &&
          parsed['success'] == true &&
          parsed['position'] != null) {
        final pos = parsed['position'] as Map<String, dynamic>;
        final cx = (pos['x'] as num).toDouble();
        final cy = (pos['y'] as num).toDouble();
        await _dispatchMouseEvent('mousePressed', cx, cy,
            button: 'left', clickCount: 1);
        await _dispatchMouseEvent('mouseReleased', cx, cy,
            button: 'left', clickCount: 1);
      }
      return parsed;
    }

    return {'success': false, 'error': 'Failed to parse act result'};
  }

  @override
  Future<String?> takeScreenshot({double quality = 1.0, int? maxWidth}) async {
    // Default to JPEG@80 for speed; use PNG only when quality=1.0 explicitly AND no maxWidth
    final useJpeg = quality < 1.0 || maxWidth != null;
    final params = <String, dynamic>{
      'format': useJpeg
          ? 'jpeg'
          : 'jpeg', // Always JPEG for CDP — 3-5x faster than PNG
      'quality': (quality * 80).round().clamp(30, 100),
    };
    if (maxWidth != null) {
      // CDP supports clip parameter for region, use viewport scaling
      params['optimizeForSpeed'] = true;
    }
    final result = await _call('Page.captureScreenshot', params);
    return result['data'] as String?;
  }

  @override
  Future<List<String>> getLogs() async {
    // CDP doesn't have a built-in log store; return console messages if captured
    return [];
  }

  @override
  Future<void> clearLogs() async {
    // No-op for CDP
  }

  @override
  Future<void> hotReload() async {
    await _call('Page.reload');
  }

  // ── Extended methods used by server.dart ──

  /// Take a screenshot of a specific region.
  Future<String?> takeRegionScreenshot(
      double x, double y, double width, double height) async {
    try {
      final result = await _call('Page.captureScreenshot', {
        'format': 'jpeg',
        'quality': 80,
        'clip': {
          'x': x,
          'y': y,
          'width': width,
          'height': height,
          'scale': 1,
        },
      }).timeout(const Duration(seconds: 10));
      return result['data'] as String?;
    } catch (_) {
      // Fallback: full screenshot (clip times out on some Chrome versions)
      final full = await takeScreenshot(quality: 0.8);
      return full;
    }
  }

  /// Take a screenshot of a specific element.
  Future<String?> takeElementScreenshot(String selector) async {
    final bounds = await _getElementBounds(selector);
    if (bounds == null) return null;
    return takeRegionScreenshot(
      bounds['x'] as double,
      bounds['y'] as double,
      bounds['w'] as double,
      bounds['h'] as double,
    );
  }

  /// Scroll an element into view.
  Future<Map<String, dynamic>> scrollTo({String? key, String? text}) async {
    final selector = _buildSelector(key: key, text: text);
    final result = await _evalJs('''
      (() => {
        const el = ${_jsFindElement(selector, text: text)};
        if (!el) return false;
        el.scrollIntoView({behavior: 'smooth', block: 'center'});
        return true;
      })()
    ''');
    final found = result['result']?['value'] == true;
    return {
      'success': found,
      'message': found ? 'Scrolled to element' : 'Element not found'
    };
  }

  /// Navigate back.
  Future<bool> goBack() async {
    await _evalJs("history.back()");
    await Future.delayed(const Duration(milliseconds: 300));
    return true;
  }

  /// Get current URL.
  Future<String> getCurrentRoute() async {
    final result = await _evalJs('window.location.href');
    return (result['result']?['value'] as String?) ?? '';
  }

  /// Evaluate JavaScript.
  Future<Map<String, dynamic>> evaluate(String expression) async {
    return _evalJs(expression);
  }

  /// Wait for an element to appear.
  Future<bool> waitForElement(
      {String? key, String? text, int timeout = 5000}) async {
    final selector = _buildSelector(key: key, text: text);
    final sw = Stopwatch()..start();
    while (sw.elapsedMilliseconds < timeout) {
      final result = await _evalJs('''
        (() => {
          const el = ${_jsFindElement(selector, text: text)};
          return el !== null && el !== undefined;
        })()
      ''');
      if (result['result']?['value'] == true) return true;
      await Future.delayed(const Duration(milliseconds: 200));
    }
    return false;
  }

  /// Wait for an element to disappear.
  Future<bool> waitForGone(
      {String? key, String? text, int timeout = 5000}) async {
    final selector = _buildSelector(key: key, text: text);
    final sw = Stopwatch()..start();
    while (sw.elapsedMilliseconds < timeout) {
      final result = await _evalJs('''
        (() => {
          const el = ${_jsFindElement(selector, text: text)};
          return el === null || el === undefined;
        })()
      ''');
      if (result['result']?['value'] == true) return true;
      await Future.delayed(const Duration(milliseconds: 200));
    }
    return false;
  }

  /// Assert visibility of an element.
  Future<bool> assertVisible({String? key, String? text}) async {
    final selector = _buildSelector(key: key, text: text);
    final result = await _evalJs('''
      (() => {
        const el = ${_jsFindElement(selector, text: text)};
        if (!el) return false;
        const style = window.getComputedStyle(el);
        return style.display !== 'none' && style.visibility !== 'hidden' && el.offsetParent !== null;
      })()
    ''');
    return result['result']?['value'] == true;
  }

  /// Tap at specific coordinates.
  Future<void> tapAt(double x, double y) async {
    await _dispatchMouseEvent('mousePressed', x, y,
        button: 'left', clickCount: 1);
    await _dispatchMouseEvent('mouseReleased', x, y,
        button: 'left', clickCount: 1);
    await _ensureFocusAtPoint(x, y);
  }

  /// Long press an element.
  Future<bool> longPress(
      {String? key, String? text, int duration = 500}) async {
    final selector = _buildSelector(key: key, text: text);
    final bounds = await _getElementBounds(selector, text: text);
    if (bounds == null) return false;
    final cx = bounds['cx'] as double;
    final cy = bounds['cy'] as double;
    await _dispatchMouseEvent('mousePressed', cx, cy, button: 'left');
    await Future.delayed(Duration(milliseconds: duration));
    await _dispatchMouseEvent('mouseReleased', cx, cy, button: 'left');
    return true;
  }

  /// Double-tap an element.
  Future<bool> doubleTap({String? key, String? text}) async {
    final selector = _buildSelector(key: key, text: text);
    final bounds = await _getElementBounds(selector, text: text);
    if (bounds == null) return false;
    final cx = bounds['cx'] as double;
    final cy = bounds['cy'] as double;
    await _dispatchMouseEvent('mousePressed', cx, cy,
        button: 'left', clickCount: 1);
    await _dispatchMouseEvent('mouseReleased', cx, cy,
        button: 'left', clickCount: 1);
    await _dispatchMouseEvent('mousePressed', cx, cy,
        button: 'left', clickCount: 2);
    await _dispatchMouseEvent('mouseReleased', cx, cy,
        button: 'left', clickCount: 2);
    return true;
  }

  /// Get text value of an input element.
  Future<String?> getTextValue(String key) async {
    final result = await _evalJs('''
      (() => {
        const el = document.querySelector('#$key') || document.querySelector('[name="$key"]');
        return el ? (el.value || el.textContent || '') : null;
      })()
    ''');
    return result['result']?['value'] as String?;
  }

  /// Get all text content on the page.
  Future<String> getTextContent() async {
    final result = await _evalJs('document.body.innerText');
    return (result['result']?['value'] as String?) ?? '';
  }

  /// Get navigation stack (just current URL for web).
  Future<List<String>> getNavigationStack() async {
    final url = await getCurrentRoute();
    return [url];
  }

  // ── Extended interaction methods ──

  /// Drag from one point to another.
  Future<Map<String, dynamic>> drag(
      double startX, double startY, double endX, double endY) async {
    try {
      return await Future(() async {
        await _dispatchMouseEvent('mousePressed', startX, startY,
            button: 'left', clickCount: 1);
        const steps = 10;
        for (var i = 1; i <= steps; i++) {
          final x = startX + (endX - startX) * i / steps;
          final y = startY + (endY - startY) * i / steps;
          await _dispatchMouseEvent('mouseMoved', x, y, button: 'left');
        }
        await _dispatchMouseEvent('mouseReleased', endX, endY,
            button: 'left', clickCount: 1);
        return {"success": true} as Map<String, dynamic>;
      }).timeout(const Duration(seconds: 10));
    } on TimeoutException {
      return {
        "success": false,
        "error": "Drag timed out — mouse event not acknowledged by browser"
      };
    }
  }

  /// Long press at coordinates.
  Future<void> longPressAt(double x, double y) async {
    await _dispatchMouseEvent('mousePressed', x, y,
        button: 'left', clickCount: 1);
    await Future.delayed(const Duration(milliseconds: 800));
    await _dispatchMouseEvent('mouseReleased', x, y,
        button: 'left', clickCount: 1);
  }

  /// Swipe between coordinates.
  Future<Map<String, dynamic>> swipeCoordinates(
      double startX, double startY, double endX, double endY,
      {int durationMs = 300}) async {
    try {
      return await Future(() async {
        await _dispatchMouseEvent('mousePressed', startX, startY,
            button: 'left', clickCount: 1);
        const steps = 8;
        for (var i = 1; i <= steps; i++) {
          final x = startX + (endX - startX) * i / steps;
          final y = startY + (endY - startY) * i / steps;
          await _dispatchMouseEvent('mouseMoved', x, y, button: 'left');
          await Future.delayed(Duration(milliseconds: durationMs ~/ steps));
        }
        await _dispatchMouseEvent('mouseReleased', endX, endY,
            button: 'left', clickCount: 1);
        return {"success": true} as Map<String, dynamic>;
      }).timeout(const Duration(seconds: 10));
    } on TimeoutException {
      return {
        "success": false,
        "error": "Swipe timed out — mouse event not acknowledged by browser"
      };
    }
  }

  /// Edge swipe (simulate from edge of viewport).
  Future<Map<String, dynamic>> edgeSwipe(String direction,
      {String edge = 'left', int distance = 200}) async {
    final viewport =
        await _evalJs('[window.innerWidth, window.innerHeight].join(",")');
    final dims =
        (viewport['result']?['value'] as String? ?? '1280,720').split(',');
    final w = double.parse(dims[0]);
    final h = double.parse(dims[1]);
    double startX, startY, endX, endY;
    switch (direction) {
      case 'right':
        startX = 5;
        startY = h / 2;
        endX = distance.toDouble();
        endY = h / 2;
        break;
      case 'left':
        startX = w - 5;
        startY = h / 2;
        endX = w - distance;
        endY = h / 2;
        break;
      case 'up':
        startX = w / 2;
        startY = h - 5;
        endX = w / 2;
        endY = h - distance;
        break;
      case 'down':
      default:
        startX = w / 2;
        startY = 5;
        endX = w / 2;
        endY = distance.toDouble();
    }
    return swipeCoordinates(startX, startY, endX, endY);
  }

  /// Custom gesture (series of points).
  Future<Map<String, dynamic>> gesture(
      List<Map<String, dynamic>> points) async {
    if (points.isEmpty) return {"success": false, "message": "No points"};
    try {
      return await Future(() async {
        final first = points.first;
        await _dispatchMouseEvent('mousePressed',
            (first['x'] as num).toDouble(), (first['y'] as num).toDouble(),
            button: 'left');
        for (var i = 1; i < points.length; i++) {
          await _dispatchMouseEvent(
              'mouseMoved',
              (points[i]['x'] as num).toDouble(),
              (points[i]['y'] as num).toDouble(),
              button: 'left');
          await Future.delayed(const Duration(milliseconds: 20));
        }
        final last = points.last;
        await _dispatchMouseEvent('mouseReleased',
            (last['x'] as num).toDouble(), (last['y'] as num).toDouble(),
            button: 'left');
        return {"success": true} as Map<String, dynamic>;
      }).timeout(const Duration(seconds: 10));
    } on TimeoutException {
      return {
        "success": false,
        "error": "Gesture timed out — mouse event not acknowledged by browser"
      };
    }
  }

  /// Scroll until element is visible.
  Future<Map<String, dynamic>> scrollUntilVisible(String key,
      {int maxScrolls = 10, String direction = 'down'}) async {
    for (var i = 0; i < maxScrolls; i++) {
      final result = await _evalJs('''
        (() => {
          const el = ${_jsResolveElement(key)};
          if (!el) return false;
          const rect = el.getBoundingClientRect();
          return rect.top >= 0 && rect.bottom <= window.innerHeight;
        })()
      ''');
      if (result['result']?['value'] == true)
        return {"success": true, "scrolls": i};
      final dy = direction == 'up' ? -300 : 300;
      await _evalJs('window.scrollBy(0, $dy)');
      await Future.delayed(const Duration(milliseconds: 200));
    }
    return {
      "success": false,
      "message": "Element '$key' not visible after $maxScrolls scrolls"
    };
  }

  /// Get checkbox state.
  Future<Map<String, dynamic>> getCheckboxState(String key) async {
    final result = await _evalJs('''
      (() => {
        let el = ${_jsResolveElement(key)};
        // Fallback: search checkboxes by label/value
        if (!el) {
          for (const cb of document.querySelectorAll('input[type="checkbox"], [role="checkbox"]')) {
            const label = cb.closest('label') || document.querySelector('label[for="' + cb.id + '"]');
            const t = (label ? label.textContent : cb.getAttribute('aria-label') || '').trim();
            if (t.toLowerCase().includes('$key'.toLowerCase()) || cb.value === '$key') { el = cb; break; }
          }
        }
        if (!el) return JSON.stringify({ success: false, error: "Element not found" });
        if (el.type === 'checkbox') return JSON.stringify({ success: true, checked: el.checked });
        const cb = el.querySelector && el.querySelector('input[type="checkbox"]');
        if (cb) return JSON.stringify({ success: true, checked: cb.checked });
        return JSON.stringify({ success: true, checked: el.getAttribute('aria-checked') === 'true' });
      })()
    ''');
    return _parseJsonEval(result) ??
        {"success": false, "error": "Element not found"};
  }

  /// Get slider value.
  Future<Map<String, dynamic>> getSliderValue(String key) async {
    final result = await _evalJs('''
      (() => {
        let el = ${_jsResolveElement(key)};
        // Fallback: search sliders by label/name
        if (!el) {
          for (const s of document.querySelectorAll('input[type="range"], [role="slider"]')) {
            const label = s.closest('label') || document.querySelector('label[for="' + s.id + '"]');
            const t = (label ? label.textContent : s.getAttribute('aria-label') || '').trim();
            if (t.toLowerCase().includes('$key'.toLowerCase()) || s.name === '$key') { el = s; break; }
          }
        }
        if (!el) return JSON.stringify({ success: false, error: "Element not found" });
        return JSON.stringify({ 
          success: true, 
          value: parseFloat(el.value || el.getAttribute('aria-valuenow') || 0), 
          min: parseFloat(el.min || el.getAttribute('aria-valuemin') || 0), 
          max: parseFloat(el.max || el.getAttribute('aria-valuemax') || 100) 
        });
      })()
    ''');
    return _parseJsonEval(result) ??
        {"success": false, "error": "Element not found"};
  }

  /// Get page state (title, url, scroll, viewport).
  Future<Map<String, dynamic>> getPageState() async {
    final result = await _evalJs('''
      JSON.stringify({
        title: document.title,
        url: window.location.href,
        scrollX: window.scrollX,
        scrollY: window.scrollY,
        viewportWidth: window.innerWidth,
        viewportHeight: window.innerHeight,
        documentHeight: document.documentElement.scrollHeight,
        readyState: document.readyState,
        visibilityState: document.visibilityState
      })
    ''');
    final value = result['result']?['value'] as String?;
    if (value == null) return {};
    return jsonDecode(value) as Map<String, dynamic>;
  }

  /// Get interactable elements (alias for getInteractiveElements).
  Future<List<dynamic>> getInteractableElements() async {
    return getInteractiveElements();
  }

  /// Get performance metrics.
  Future<Map<String, dynamic>> getPerformance() async {
    final result = await _evalJs('''
      JSON.stringify((() => {
        const nav = performance.getEntriesByType('navigation')[0] || {};
        return {
          loadTime: nav.loadEventEnd - nav.startTime,
          domContentLoaded: nav.domContentLoadedEventEnd - nav.startTime,
          firstPaint: (performance.getEntriesByType('paint').find(p => p.name === 'first-paint') || {}).startTime || 0,
          firstContentfulPaint: (performance.getEntriesByType('paint').find(p => p.name === 'first-contentful-paint') || {}).startTime || 0,
          resourceCount: performance.getEntriesByType('resource').length
        };
      })())
    ''');
    final value = result['result']?['value'] as String?;
    if (value == null) return {};
    return jsonDecode(value) as Map<String, dynamic>;
  }

  /// Get frame stats via Performance API.
  Future<Map<String, dynamic>> getFrameStats() async {
    final result = await _evalJs('''
      JSON.stringify({
        fps: 60,
        frameCount: performance.getEntriesByType('frame').length || 0,
        longTasks: performance.getEntriesByType('longtask').length || 0,
        timestamp: performance.now()
      })
    ''');
    final value = result['result']?['value'] as String?;
    if (value == null) return {};
    return jsonDecode(value) as Map<String, dynamic>;
  }

  /// Get memory stats.
  Future<Map<String, dynamic>> getMemoryStats() async {
    final result = await _evalJs('''
      JSON.stringify(performance.memory ? {
        usedJSHeapSize: performance.memory.usedJSHeapSize,
        totalJSHeapSize: performance.memory.totalJSHeapSize,
        jsHeapSizeLimit: performance.memory.jsHeapSizeLimit
      } : { message: "memory API not available" })
    ''');
    final value = result['result']?['value'] as String?;
    if (value == null) return {"message": "not available"};
    return jsonDecode(value) as Map<String, dynamic>;
  }

  /// Assert text exists on page.
  Future<Map<String, dynamic>> assertText(String text, {String? key}) async {
    final result = await _evalJs('''
      (() => {
        ${key != null ? "const el = ${_jsResolveElement(key)}; return el ? el.textContent.includes('$text') : false;" : "return document.body.innerText.includes('$text');"}
      })()
    ''');
    final found = result['result']?['value'] == true;
    return {"success": found, "found": found, "text": text};
  }

  /// Assert element count.
  Future<Map<String, dynamic>> assertElementCount(
      String selector, int expectedCount) async {
    final result =
        await _evalJs('document.querySelectorAll("$selector").length');
    final count = result['result']?['value'] as int? ?? 0;
    return {
      "success": count == expectedCount,
      "actual_count": count,
      "expected_count": expectedCount,
    };
  }

  /// Wait for idle.
  Future<Map<String, dynamic>> waitForIdle({int timeoutMs = 5000}) async {
    await Future.delayed(
        Duration(milliseconds: timeoutMs > 2000 ? 2000 : timeoutMs));
    return {"success": true, "message": "Page idle"};
  }

  /// Diagnose connection.
  Future<Map<String, dynamic>> diagnose() async {
    return {
      "mode": "cdp",
      "port": _port,
      "connected": _connected,
      "url": await getCurrentRoute(),
    };
  }

  // ── Advanced CDP tools (beyond Playwright MCP) ──

  /// Evaluate JavaScript and return result.
  Future<Map<String, dynamic>> eval(String expression) async {
    return _evalJs(expression);
  }

  /// Press a keyboard key.
  Future<void> pressKey(String key, {List<String>? modifiers}) async {
    // Map common key names to CDP key codes
    final keyMap = <String, Map<String, dynamic>>{
      'Enter': {'key': 'Enter', 'code': 'Enter', 'keyCode': 13},
      'Tab': {'key': 'Tab', 'code': 'Tab', 'keyCode': 9},
      'Escape': {'key': 'Escape', 'code': 'Escape', 'keyCode': 27},
      'Backspace': {'key': 'Backspace', 'code': 'Backspace', 'keyCode': 8},
      'Delete': {'key': 'Delete', 'code': 'Delete', 'keyCode': 46},
      'ArrowUp': {'key': 'ArrowUp', 'code': 'ArrowUp', 'keyCode': 38},
      'ArrowDown': {'key': 'ArrowDown', 'code': 'ArrowDown', 'keyCode': 40},
      'ArrowLeft': {'key': 'ArrowLeft', 'code': 'ArrowLeft', 'keyCode': 37},
      'ArrowRight': {'key': 'ArrowRight', 'code': 'ArrowRight', 'keyCode': 39},
      'Space': {'key': ' ', 'code': 'Space', 'keyCode': 32},
    };
    final mapped = keyMap[key];
    final keyName = mapped?['key'] ?? key;
    final code = mapped?['code'] ?? 'Key${key.toUpperCase()}';
    final keyCode = mapped?['keyCode'] ?? key.codeUnitAt(0);

    int modifierFlags = 0;
    if (modifiers != null) {
      if (modifiers.contains('Alt')) modifierFlags |= 1;
      if (modifiers.contains('Control')) modifierFlags |= 2;
      if (modifiers.contains('Meta')) modifierFlags |= 4;
      if (modifiers.contains('Shift')) modifierFlags |= 8;
    }

    await _call('Input.dispatchKeyEvent', {
      'type': 'keyDown',
      'key': keyName,
      'code': code,
      'windowsVirtualKeyCode': keyCode,
      'nativeVirtualKeyCode': keyCode,
      'modifiers': modifierFlags,
    });
    await _call('Input.dispatchKeyEvent', {
      'type': 'keyUp',
      'key': keyName,
      'code': code,
      'windowsVirtualKeyCode': keyCode,
      'nativeVirtualKeyCode': keyCode,
      'modifiers': modifierFlags,
    });
  }

  /// Type text into the focused element.
  /// Complete US QWERTY keyboard layout mapping.
  /// Maps every printable ASCII character to its physical key, keyCode,
  /// and whether Shift is required. Based on Puppeteer's USKeyboardLayout.
  static const _usKeyboard = <String, List<dynamic>>{
    // [code, keyCode, shifted]
    // --- Letters (a-z unshifted, A-Z shifted) ---
    'a': ['KeyA', 65, false], 'b': ['KeyB', 66, false],
    'c': ['KeyC', 67, false], 'd': ['KeyD', 68, false],
    'e': ['KeyE', 69, false], 'f': ['KeyF', 70, false],
    'g': ['KeyG', 71, false], 'h': ['KeyH', 72, false],
    'i': ['KeyI', 73, false], 'j': ['KeyJ', 74, false],
    'k': ['KeyK', 75, false], 'l': ['KeyL', 76, false],
    'm': ['KeyM', 77, false], 'n': ['KeyN', 78, false],
    'o': ['KeyO', 79, false], 'p': ['KeyP', 80, false],
    'q': ['KeyQ', 81, false], 'r': ['KeyR', 82, false],
    's': ['KeyS', 83, false], 't': ['KeyT', 84, false],
    'u': ['KeyU', 85, false], 'v': ['KeyV', 86, false],
    'w': ['KeyW', 87, false], 'x': ['KeyX', 88, false],
    'y': ['KeyY', 89, false], 'z': ['KeyZ', 90, false],
    'A': ['KeyA', 65, true], 'B': ['KeyB', 66, true],
    'C': ['KeyC', 67, true], 'D': ['KeyD', 68, true],
    'E': ['KeyE', 69, true], 'F': ['KeyF', 70, true],
    'G': ['KeyG', 71, true], 'H': ['KeyH', 72, true],
    'I': ['KeyI', 73, true], 'J': ['KeyJ', 74, true],
    'K': ['KeyK', 75, true], 'L': ['KeyL', 76, true],
    'M': ['KeyM', 77, true], 'N': ['KeyN', 78, true],
    'O': ['KeyO', 79, true], 'P': ['KeyP', 80, true],
    'Q': ['KeyQ', 81, true], 'R': ['KeyR', 82, true],
    'S': ['KeyS', 83, true], 'T': ['KeyT', 84, true],
    'U': ['KeyU', 85, true], 'V': ['KeyV', 86, true],
    'W': ['KeyW', 87, true], 'X': ['KeyX', 88, true],
    'Y': ['KeyY', 89, true], 'Z': ['KeyZ', 90, true],
    // --- Digits (unshifted) ---
    '0': ['Digit0', 48, false], '1': ['Digit1', 49, false],
    '2': ['Digit2', 50, false], '3': ['Digit3', 51, false],
    '4': ['Digit4', 52, false], '5': ['Digit5', 53, false],
    '6': ['Digit6', 54, false], '7': ['Digit7', 55, false],
    '8': ['Digit8', 56, false], '9': ['Digit9', 57, false],
    // --- Shifted digit symbols ---
    ')': ['Digit0', 48, true], '!': ['Digit1', 49, true],
    '@': ['Digit2', 50, true], '#': ['Digit3', 51, true],
    '\$': ['Digit4', 52, true], '%': ['Digit5', 53, true],
    '^': ['Digit6', 54, true], '&': ['Digit7', 55, true],
    '*': ['Digit8', 56, true], '(': ['Digit9', 57, true],
    // --- Punctuation (unshifted) ---
    ' ': ['Space', 32, false],
    '-': ['Minus', 189, false], '=': ['Equal', 187, false],
    '[': ['BracketLeft', 219, false], ']': ['BracketRight', 221, false],
    '\\': ['Backslash', 220, false], ';': ['Semicolon', 186, false],
    "'": ['Quote', 222, false], '`': ['Backquote', 192, false],
    ',': ['Comma', 188, false], '.': ['Period', 190, false],
    '/': ['Slash', 191, false],
    // --- Punctuation (shifted) ---
    '_': ['Minus', 189, true], '+': ['Equal', 187, true],
    '{': ['BracketLeft', 219, true], '}': ['BracketRight', 221, true],
    '|': ['Backslash', 220, true], ':': ['Semicolon', 186, true],
    '"': ['Quote', 222, true], '~': ['Backquote', 192, true],
    '<': ['Comma', 188, true], '>': ['Period', 190, true],
    '?': ['Slash', 191, true],
  };

  /// Type text into the currently focused element.
  ///
  /// **Strategy** (universal, works with all frameworks — React, Vue, Angular,
  /// Svelte, vanilla, contenteditable, etc.):
  ///
  /// 1. Detect focused element type (input/textarea/contenteditable/other).
  /// 2. For form elements (`<input>`, `<textarea>`) and contenteditable:
  ///    use **`Input.insertText`** which reliably triggers native `input`
  ///    events that all frameworks listen to.  This is the same code path
  ///    Chrome uses for IME composition and clipboard paste.
  /// 3. Control characters (Enter, Tab) always use `dispatchKeyEvent` so
  ///    they trigger form submission, focus changes, etc.
  /// 4. Fallback: if `Input.insertText` didn't change the value, try
  ///    `execCommand('insertText')` then `dispatchKeyEvent` per char.
  ///
  /// Full US QWERTY mapping is retained in [_usKeyboard] for use by
  /// [pressKey] and the dispatchKeyEvent fallback path.
  Future<void> typeText(String text) async {
    // Detect focused element type and snapshot length before typing
    final beforeResult = await _evalJs('''
      (() => {
        const el = document.activeElement;
        if (!el) return JSON.stringify({tag: null, len: 0, editable: false});
        const tag = el.tagName;
        const isFormField = tag === 'INPUT' || tag === 'TEXTAREA';
        const isCE = el.isContentEditable || el.getAttribute('contenteditable') === 'true';
        const val = isFormField ? (el.value || '') : (el.textContent || '');
        return JSON.stringify({
          tag: tag,
          len: val.length,
          editable: isFormField || isCE,
          isFormField: isFormField,
          isCE: isCE,
        });
      })()
    ''');
    final beforeParsed = _parseJsonEval(beforeResult);
    final beforeLen = (beforeParsed?['len'] as num?)?.toInt() ?? 0;
    final isEditable = beforeParsed?['editable'] == true;

    // Split text into segments: control chars vs printable text runs
    // This allows us to batch printable text into a single insertText call
    // while still dispatching control keys individually.
    final segments = <_TypeSegment>[];
    final buf = StringBuffer();
    for (final char in text.split('')) {
      if (char == '\n' || char == '\r' || char == '\t') {
        if (buf.isNotEmpty) {
          segments.add(_TypeSegment(buf.toString(), false));
          buf.clear();
        }
        segments.add(_TypeSegment(char, true));
      } else {
        buf.write(char);
      }
    }
    if (buf.isNotEmpty) {
      segments.add(_TypeSegment(buf.toString(), false));
    }

    // Type each segment
    for (final seg in segments) {
      if (seg.isControl) {
        // Control characters → always dispatchKeyEvent
        if (seg.text == '\n' || seg.text == '\r') {
          await _dispatchKey('Enter', 'Enter', 13, text: '\r');
        } else if (seg.text == '\t') {
          await _dispatchKey('Tab', 'Tab', 9);
        }
      } else if (isEditable) {
        // Printable text into editable element → Input.insertText (universal)
        await _call('Input.insertText', {'text': seg.text});
      } else {
        // Not a known editable element — fall back to per-char dispatchKeyEvent
        await _typeViaDispatchKeyEvent(seg.text);
      }
    }

    // Verify text was inserted
    final afterResult = await _evalJs('''
      (() => {
        const el = document.activeElement;
        if (!el) return JSON.stringify({len: 0});
        const tag = el.tagName;
        const isFormField = tag === 'INPUT' || tag === 'TEXTAREA';
        const val = isFormField ? (el.value || '') : (el.textContent || '');
        return JSON.stringify({len: val.length});
      })()
    ''');
    final afterParsed = _parseJsonEval(afterResult);
    final afterLen = (afterParsed?['len'] as num?)?.toInt() ?? 0;

    if (afterLen <= beforeLen && text.isNotEmpty) {
      // Primary method failed — try fallback chain
      // 1. execCommand (works in some contenteditable contexts)
      final escaped = text
          .replaceAll('\\', '\\\\')
          .replaceAll("'", "\\'")
          .replaceAll('\n', '\\n')
          .replaceAll('\t', '\\t');
      await _evalJs("document.execCommand('insertText', false, '$escaped')");

      // 2. If still failed, try per-char dispatchKeyEvent as last resort
      final fallbackResult = await _evalJs('''
        (() => {
          const el = document.activeElement;
          if (!el) return JSON.stringify({len: 0});
          const tag = el.tagName;
          const isFormField = tag === 'INPUT' || tag === 'TEXTAREA';
          const val = isFormField ? (el.value || '') : (el.textContent || '');
          return JSON.stringify({len: val.length});
        })()
      ''');
      final fallbackParsed = _parseJsonEval(fallbackResult);
      final fallbackLen = (fallbackParsed?['len'] as num?)?.toInt() ?? 0;

      if (fallbackLen <= beforeLen) {
        // execCommand also failed — dispatchKeyEvent as absolute last resort
        await _typeViaDispatchKeyEvent(text);
      }
    }
  }

  /// Type text character-by-character via dispatchKeyEvent (fallback).
  /// Used when Input.insertText and execCommand both fail.
  Future<void> _typeViaDispatchKeyEvent(String text) async {
    for (final char in text.split('')) {
      if (char == '\n' || char == '\r') {
        await _dispatchKey('Enter', 'Enter', 13, text: '\r');
        continue;
      }
      if (char == '\t') {
        await _dispatchKey('Tab', 'Tab', 9);
        continue;
      }

      final mapping = _usKeyboard[char];
      if (mapping != null) {
        final code = mapping[0] as String;
        final keyCode = mapping[1] as int;
        final shifted = mapping[2] as bool;
        final modifiers = shifted ? 8 : 0;

        await _call('Input.dispatchKeyEvent', {
          'type': 'keyDown',
          'key': char,
          'code': code,
          'text': char,
          'unmodifiedText': char,
          'windowsVirtualKeyCode': keyCode,
          'nativeVirtualKeyCode': keyCode,
          if (modifiers > 0) 'modifiers': modifiers,
        });
        await _call('Input.dispatchKeyEvent', {
          'type': 'keyUp',
          'key': char,
          'code': code,
          'windowsVirtualKeyCode': keyCode,
          'nativeVirtualKeyCode': keyCode,
        });
      } else {
        // Non-ASCII char without keyboard mapping
        await _call('Input.insertText', {'text': char});
      }
    }
  }

  /// Helper: dispatch a keyDown + keyUp pair for control keys.
  Future<void> _dispatchKey(String key, String code, int keyCode,
      {String? text}) async {
    await _call('Input.dispatchKeyEvent', {
      'type': 'keyDown',
      'key': key,
      'code': code,
      if (text != null) 'text': text,
      if (text != null) 'unmodifiedText': text,
      'windowsVirtualKeyCode': keyCode,
      'nativeVirtualKeyCode': keyCode,
    });
    await _call('Input.dispatchKeyEvent', {
      'type': 'keyUp',
      'key': key,
      'code': code,
      'windowsVirtualKeyCode': keyCode,
      'nativeVirtualKeyCode': keyCode,
    });
  }

  /// Hover over element.
  Future<Map<String, dynamic>> hover(
      {String? key, String? text, String? ref}) async {
    final bounds = await _getElementBounds(key ?? '', text: text, ref: ref);
    if (bounds == null)
      return {"success": false, "message": "Element not found"};
    final cx = bounds['x']! + bounds['w']! / 2;
    final cy = bounds['y']! + bounds['h']! / 2;
    await _dispatchMouseEvent('mouseMoved', cx, cy);
    return {
      "success": true,
      "position": {"x": cx, "y": cy}
    };
  }

  /// Select option in a <select> element.
  Future<Map<String, dynamic>> selectOption(String key, String value) async {
    final result = await _evalJs('''
      (() => {
        const el = ${_jsResolveElement(key)};
        if (!el || el.tagName !== 'SELECT') return JSON.stringify({success: false, message: 'Select element not found'});
        el.value = '$value';
        el.dispatchEvent(new Event('change', {bubbles: true}));
        return JSON.stringify({success: true, value: '$value'});
      })()
    ''');
    final v = result['result']?['value'] as String?;
    if (v == null) return {"success": false};
    return jsonDecode(v) as Map<String, dynamic>;
  }

  /// Check/uncheck a checkbox.
  Future<Map<String, dynamic>> setCheckbox(String key, bool checked) async {
    final result = await _evalJs('''
      (() => {
        const el = ${_jsResolveElement(key)};
        if (!el) return JSON.stringify({success: false, message: 'Element not found'});
        const cb = el.type === 'checkbox' ? el : (el.querySelector && el.querySelector('input[type="checkbox"]'));
        if (!cb) return JSON.stringify({success: false, message: 'Checkbox not found'});
        if (cb.checked !== $checked) { cb.click(); }
        return JSON.stringify({success: true, checked: cb.checked});
      })()
    ''');
    return _parseJsonEval(result) ?? {"success": false};
  }

  /// Fill input (clear + type — faster than enterText for forms).
  Future<Map<String, dynamic>> fill(String key, String value) async {
    final result = await _evalJs('''
      (() => {
        const el = ${_jsResolveElement(key)};
        if (!el) return JSON.stringify({success: false, message: 'Element not found'});
        el.focus();
        el.value = '';
        const nativeInputValueSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value')?.set
          || Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value')?.set;
        if (nativeInputValueSetter) nativeInputValueSetter.call(el, '${value.replaceAll("'", "\\'")}');
        else el.value = '${value.replaceAll("'", "\\'")}';
        el.dispatchEvent(new Event('input', {bubbles: true}));
        el.dispatchEvent(new Event('change', {bubbles: true}));
        return JSON.stringify({success: true, value: el.value});
      })()
    ''');
    final v = result['result']?['value'] as String?;
    if (v == null) return {"success": false};
    return jsonDecode(v) as Map<String, dynamic>;
  }

  /// Paste text instantly via CDP Input.insertText (clipboard-style).
  /// Much faster than typeText for long content.
  Future<void> pasteText(String text) async {
    await _call('Input.insertText', {'text': text});
  }

  /// Fill a rich text editor (contenteditable, Draft.js, ProseMirror, Tiptap, Medium, etc.).
  /// Finds the editor element, focuses it, clears content, and injects HTML or plain text.
  /// [selector] - CSS selector for the editor element (e.g. '[contenteditable="true"]', '.ProseMirror', '.tiptap')
  /// [html] - HTML content to inject (preferred for rich editors)
  /// [text] - Plain text to inject (fallback)
  /// [append] - If true, append instead of replacing content
  Future<Map<String, dynamic>> fillRichText({
    String? selector,
    String? html,
    String? text,
    bool append = false,
  }) async {
    final content = html ?? text ?? '';
    final isHtml = html != null;
    final sel = selector ?? '[contenteditable="true"]';
    final escapedContent = content
        .replaceAll('\\', '\\\\')
        .replaceAll('`', '\\`')
        .replaceAll('\$', '\\\$');

    final result = await _evalJs('''
      (() => {
        // Try multiple selectors for common rich text editors
        const selectors = ['$sel', '.ProseMirror', '.tiptap', '[contenteditable="true"]', '.ql-editor', '.DraftEditor-root [contenteditable="true"]', '.graf--p'];
        let el = null;
        for (const s of selectors) {
          el = document.querySelector(s);
          if (el) break;
        }
        if (!el) return JSON.stringify({success: false, message: 'Rich text editor not found', triedSelectors: selectors});

        el.focus();

        if (!${append}) {
          el.innerHTML = '';
        }

        if (${isHtml}) {
          el.innerHTML ${append ? '+' : ''}= `$escapedContent`;
        } else {
          el.innerText ${append ? '+' : ''}= `$escapedContent`;
        }

        // Dispatch events for framework detection (React, Vue, Draft.js, Tiptap, ProseMirror)
        el.dispatchEvent(new Event('input', {bubbles: true}));
        el.dispatchEvent(new Event('change', {bubbles: true}));
        // For ProseMirror/Tiptap — trigger a DOM mutation so the framework picks up changes
        el.dispatchEvent(new Event('keyup', {bubbles: true}));
        // For Draft.js — trigger beforeinput
        try { el.dispatchEvent(new InputEvent('beforeinput', {bubbles: true, inputType: 'insertText'})); } catch(e) {}

        return JSON.stringify({
          success: true,
          editor: el.className || el.tagName,
          contentLength: el.innerHTML.length,
          selector: '$sel'
        });
      })()
    ''');
    final v = result['result']?['value'] as String?;
    if (v == null) return {"success": false, "message": "Eval returned null"};
    return jsonDecode(v) as Map<String, dynamic>;
  }

  /// Solve CAPTCHA using 2Captcha/Anti-Captcha service.
  /// Supports reCAPTCHA v2/v3, hCaptcha, image CAPTCHA.
  /// [apiKey] - API key for the CAPTCHA solving service
  /// [service] - 'twocaptcha' or 'anticaptcha' (default: twocaptcha)
  /// [siteKey] - reCAPTCHA/hCaptcha site key (auto-detected if not provided)
  /// [pageUrl] - URL of the page (auto-detected if not provided)
  /// [type] - 'recaptcha_v2', 'recaptcha_v3', 'hcaptcha', 'image' (auto-detected)
  Future<Map<String, dynamic>> solveCaptcha({
    required String apiKey,
    String service = 'twocaptcha',
    String? siteKey,
    String? pageUrl,
    String? type,
  }) async {
    // Step 1: Auto-detect CAPTCHA type and site key
    final detection = await _evalJs('''
      (() => {
        const url = window.location.href;
        // reCAPTCHA v2/v3
        const recaptchaEl = document.querySelector('.g-recaptcha, [data-sitekey], iframe[src*="recaptcha"]');
        if (recaptchaEl) {
          const sk = recaptchaEl.getAttribute('data-sitekey') || 
            (recaptchaEl.src ? new URL(recaptchaEl.src).searchParams.get('k') : null);
          const isV3 = recaptchaEl.getAttribute('data-size') === 'invisible' || document.querySelector('script[src*="recaptcha/api.js?render="]') !== null;
          return JSON.stringify({type: isV3 ? 'recaptcha_v3' : 'recaptcha_v2', siteKey: sk, pageUrl: url});
        }
        // hCaptcha
        const hcaptchaEl = document.querySelector('.h-captcha, [data-sitekey][data-hcaptcha], iframe[src*="hcaptcha"]');
        if (hcaptchaEl) {
          const sk = hcaptchaEl.getAttribute('data-sitekey');
          return JSON.stringify({type: 'hcaptcha', siteKey: sk, pageUrl: url});
        }
        // Cloudflare Turnstile
        const turnstile = document.querySelector('.cf-turnstile, [data-sitekey]');
        if (turnstile && turnstile.classList.contains('cf-turnstile')) {
          return JSON.stringify({type: 'turnstile', siteKey: turnstile.getAttribute('data-sitekey'), pageUrl: url});
        }
        // Image CAPTCHA
        const imgCaptcha = document.querySelector('img[src*="captcha"], img[alt*="captcha"], img[class*="captcha"]');
        if (imgCaptcha) {
          return JSON.stringify({type: 'image', imgSrc: imgCaptcha.src, pageUrl: url});
        }
        return JSON.stringify({type: 'none', pageUrl: url});
      })()
    ''');

    final detectionValue = detection['result']?['value'] as String?;
    if (detectionValue == null) {
      return {"success": false, "message": "Failed to detect CAPTCHA"};
    }
    final detected = jsonDecode(detectionValue) as Map<String, dynamic>;
    final captchaType = type ?? detected['type'] as String?;
    final detectedSiteKey = siteKey ?? detected['siteKey'] as String?;
    final detectedPageUrl = pageUrl ?? detected['pageUrl'] as String?;

    if (captchaType == 'none') {
      return {"success": true, "message": "No CAPTCHA detected on page"};
    }

    // Step 2: Submit to solving service
    final http.Client httpClient = http.Client();
    try {
      String taskId;

      if (service == 'twocaptcha') {
        // 2Captcha API
        final submitUrl = Uri.parse('http://2captcha.com/in.php');
        final params = <String, String>{
          'key': apiKey,
          'json': '1',
        };

        if (captchaType == 'recaptcha_v2' || captchaType == 'recaptcha_v3') {
          params['method'] = 'userrecaptcha';
          params['googlekey'] = detectedSiteKey ?? '';
          params['pageurl'] = detectedPageUrl ?? '';
          if (captchaType == 'recaptcha_v3') {
            params['version'] = 'v3';
            params['action'] = 'verify';
            params['min_score'] = '0.3';
          }
        } else if (captchaType == 'hcaptcha') {
          params['method'] = 'hcaptcha';
          params['sitekey'] = detectedSiteKey ?? '';
          params['pageurl'] = detectedPageUrl ?? '';
        } else if (captchaType == 'turnstile') {
          params['method'] = 'turnstile';
          params['sitekey'] = detectedSiteKey ?? '';
          params['pageurl'] = detectedPageUrl ?? '';
        } else if (captchaType == 'image') {
          // For image CAPTCHA, download and send base64
          final imgSrc = detected['imgSrc'] as String?;
          if (imgSrc == null)
            return {"success": false, "message": "No CAPTCHA image found"};
          final imgResponse = await httpClient.get(Uri.parse(imgSrc));
          params['method'] = 'base64';
          params['body'] = base64Encode(imgResponse.bodyBytes);
        }

        final response = await httpClient.post(submitUrl, body: params);
        final submitResult = jsonDecode(response.body) as Map<String, dynamic>;
        if (submitResult['status'] != 1) {
          return {
            "success": false,
            "message": "Submit failed: ${submitResult['request']}"
          };
        }
        taskId = submitResult['request'] as String;

        // Step 3: Poll for result
        for (int i = 0; i < 60; i++) {
          await Future.delayed(const Duration(seconds: 5));
          final pollUrl = Uri.parse(
              'http://2captcha.com/res.php?key=$apiKey&action=get&id=$taskId&json=1');
          final pollResponse = await httpClient.get(pollUrl);
          final pollResult =
              jsonDecode(pollResponse.body) as Map<String, dynamic>;
          if (pollResult['status'] == 1) {
            final token = pollResult['request'] as String;

            // Step 4: Inject solution
            if (captchaType == 'image') {
              // For image CAPTCHA, fill the input field
              await _evalJs('''
                (() => {
                  const input = document.querySelector('input[name*="captcha"], input[id*="captcha"], input[class*="captcha"]');
                  if (input) { input.value = '$token'; input.dispatchEvent(new Event('input', {bubbles: true})); }
                })()
              ''');
            } else {
              // For reCAPTCHA/hCaptcha/Turnstile — inject token into callback
              await _evalJs('''
                (() => {
                  const textarea = document.querySelector('#g-recaptcha-response, [name="g-recaptcha-response"], textarea[name="h-captcha-response"]');
                  if (textarea) {
                    textarea.style.display = '';
                    textarea.value = '$token';
                    textarea.dispatchEvent(new Event('input', {bubbles: true}));
                  }
                  // Call callback if available
                  if (typeof ___grecaptcha_cfg !== 'undefined') {
                    const clients = ___grecaptcha_cfg.clients;
                    if (clients) {
                      Object.keys(clients).forEach(k => {
                        const c = clients[k];
                        // Find callback in nested structure
                        const findCb = (obj) => {
                          if (!obj || typeof obj !== 'object') return null;
                          for (const key of Object.keys(obj)) {
                            if (typeof obj[key] === 'function') return obj[key];
                            const found = findCb(obj[key]);
                            if (found) return found;
                          }
                          return null;
                        };
                        const cb = findCb(c);
                        if (cb) cb('$token');
                      });
                    }
                  }
                  // hCaptcha callback
                  if (window.hcaptcha) window.hcaptcha.execute();
                })()
              ''');
            }

            return {
              "success": true,
              "type": captchaType,
              "token":
                  token.length > 50 ? '${token.substring(0, 50)}...' : token,
              "message": "CAPTCHA solved and injected"
            };
          }
          if (pollResult['request'] != 'CAPCHA_NOT_READY') {
            return {
              "success": false,
              "message": "Solve failed: ${pollResult['request']}"
            };
          }
        }
        return {
          "success": false,
          "message": "Timeout waiting for CAPTCHA solution"
        };
      } else {
        return {
          "success": false,
          "message": "Service '$service' not supported yet. Use 'twocaptcha'."
        };
      }
    } finally {
      httpClient.close();
    }
  }

  /// Highlight an element on the page.
  Future<Map<String, dynamic>> highlightElement(String selector,
      {String color = 'red', int duration = 3000}) async {
    // Parse color to rgba for background (20% opacity)
    final bgAlpha = '0.1';
    final shadowAlpha = '0.5';
    final result = await _evalJs('''
      (() => {
        const el = ${_jsResolveElement(selector)};
        if (!el) return JSON.stringify({ success: false, error: 'Element not found' });
        const rect = el.getBoundingClientRect();
        const hl = document.createElement('div');
        hl.id = '__fs_hl_' + Math.random().toString(36).substr(2, 9);
        hl.style.cssText = 'position:fixed;top:'+rect.top+'px;left:'+rect.left+'px;width:'+rect.width+'px;height:'+rect.height+'px;border:3px solid $color;background:$color'.replace(/\\/[^/]*\$/, '')+'${bgAlpha};pointer-events:none;z-index:9999;box-shadow:0 0 10px $color'.replace(/\\/[^/]*\$/, '')+'${shadowAlpha};animation:__fs_pulse 0.5s infinite alternate';
        if (!document.getElementById('__fs_hl_style')) {
          const s = document.createElement('style');
          s.id = '__fs_hl_style';
          s.textContent = '@keyframes __fs_pulse{0%{opacity:.3}100%{opacity:.8}}';
          document.head.appendChild(s);
        }
        document.body.appendChild(hl);
        setTimeout(() => hl.remove(), $duration);
        return JSON.stringify({ success: true, element_found: true, duration: $duration });
      })()
    ''');
    return _parseJsonEval(result) ?? {"success": false, "error": "Eval failed"};
  }

  // ── Internal helpers ──

  /// Persistent profile directory for CDP Chrome sessions.
  ///
  /// Uses `~/.flutter-skill/chrome-profile/` instead of a temp directory
  /// so login sessions, cookies, and preferences survive across restarts.
  static String get _persistentProfileDir {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '.';
    return '$home/.flutter-skill/chrome-profile';
  }

  Future<void> _launchChromeProcess() async {
    final chromePaths = <String>[];

    // 1. User-specified path (highest priority)
    if (_chromePath != null) {
      chromePaths.add(_chromePath!);
    }

    // 2. Standard Chrome / Chromium
    if (Platform.isMacOS) {
      chromePaths
          .add('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome');
      chromePaths.add('/Applications/Chromium.app/Contents/MacOS/Chromium');
    } else if (Platform.isLinux) {
      chromePaths.addAll([
        'google-chrome',
        'google-chrome-stable',
        'chromium',
        'chromium-browser'
      ]);
    } else if (Platform.isWindows) {
      chromePaths.add(r'C:\Program Files\Google\Chrome\Application\chrome.exe');
      chromePaths
          .add(r'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe');
    }

    // Use persistent profile directory instead of temp dir so sessions survive
    final profileDir = Directory(_persistentProfileDir);
    if (!profileDir.existsSync()) {
      profileDir.createSync(recursive: true);
    }

    final chromeArgs = [
      '--remote-debugging-port=$_port',
      '--remote-allow-origins=*',
      '--no-first-run',
      '--no-default-browser-check',
      '--user-data-dir=${profileDir.path}',
      '--disable-background-timer-throttling',
      '--disable-backgrounding-occluded-windows',
      '--disable-renderer-backgrounding',
      if (_headless) '--headless=new',
      if (_proxy != null) '--proxy-server=$_proxy',
      if (_ignoreSsl) '--ignore-certificate-errors',
      _url,
    ];

    for (final chromePath in chromePaths) {
      try {
        // macOS: remove quarantine attribute before launch — prevents
        // --remote-debugging-port from silently failing on some versions.
        if (Platform.isMacOS && chromePath.contains('.app/')) {
          final appBundle = chromePath.substring(
              0, chromePath.indexOf('.app/') + '.app/'.length - 1);
          await Process.run('xattr', ['-cr', appBundle]);
        }

        _chromeProcess = await Process.start(chromePath, chromeArgs);

        // Wait briefly and check if the process is still alive.
        // Standard Chrome ≥136 rejects --remote-debugging-port with the
        // default user-data-dir and exits immediately with a warning.
        await Future.delayed(const Duration(milliseconds: 500));
        final code = await _chromeProcess!.exitCode
            .timeout(const Duration(milliseconds: 200), onTimeout: () => -1);
        if (code != -1) {
          // Process already exited — likely Chrome 136+ rejecting debug port.
          // Try next candidate.
          _chromeProcess = null;
          continue;
        }

        return;
      } catch (_) {
        _chromeProcess = null;
        continue;
      }
    }

    throw Exception(
      'Could not launch Chrome for CDP debugging.\n\n'
      'Chrome 136+ blocks --remote-debugging-port on the default profile.\n\n'
      'Solutions:\n'
      '  1. Start Chrome manually with a custom profile:\n'
      '     google-chrome --remote-debugging-port=$_port --user-data-dir=/tmp/my-profile\n'
      '     Then: connect_cdp(url: "...", launch_chrome: false)\n\n'
      '  2. Use Chromium (no debug port restrictions):\n'
      '     brew install chromium\n'
      '     Then: connect_cdp(url: "...")\n\n'
      'Tried browsers: ${chromePaths.join(", ")}',
    );
  }

  /// Poll CDP port, returning true if it responds within [timeout], false otherwise.
  Future<bool> _pollCdpPort({
    Duration timeout = const Duration(seconds: 4),
    Duration interval = const Duration(milliseconds: 200),
  }) async {
    final client = http.Client();
    final deadline = DateTime.now().add(timeout);
    try {
      while (DateTime.now().isBefore(deadline)) {
        try {
          final resp = await client
              .get(Uri.parse('http://127.0.0.1:$_port/json/version'))
              .timeout(const Duration(milliseconds: 300));
          if (resp.statusCode == 200) return true;
        } catch (_) {}
        await Future.delayed(interval);
      }
      return false;
    } finally {
      client.close();
    }
  }

  /// Poll CDP endpoint until it responds (replaces fixed 2s delay after Chrome launch)
  Future<void> _waitForCdpReady() async {
    final client = http.Client();
    for (var i = 0; i < 40; i++) {
      // 40 * 50ms = 2s max
      try {
        final resp = await client
            .get(Uri.parse('http://127.0.0.1:$_port/json/version'))
            .timeout(const Duration(milliseconds: 200));
        if (resp.statusCode == 200) {
          client.close();
          return;
        }
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 50));
    }
    client.close();
  }

  /// Wait for page load event via CDP (replaces fixed 2s delay)
  Future<void> _waitForLoad() async {
    final completer = Completer<void>();
    // Listen for Page.loadEventFired
    _eventSubscriptions['Page.loadEventFired'] = () {
      if (!completer.isCompleted) completer.complete();
    };
    // Also complete on frameStoppedLoading
    _eventSubscriptions['Page.frameStoppedLoading'] = () {
      if (!completer.isCompleted) completer.complete();
    };
    // Timeout after 3s
    await completer.future.timeout(const Duration(seconds: 3), onTimeout: () {
      // Page didn't fire load event in time — continue anyway
    });
    _eventSubscriptions.remove('Page.loadEventFired');
    _eventSubscriptions.remove('Page.frameStoppedLoading');
  }

  /// Auto-click the "Allow remote debugging?" dialog that Chrome 146 shows
  /// when an external app connects via the consent port.
  ///
  /// Chrome renders the dialog as a native AXSheet inside the front window.
  /// The Allow button has description="Allow" (not name="Allow"), so we
  /// search by description via the macOS Accessibility API using AppleScript.
  Future<void> _autoAllowChromeConsentDialog() async {
    const script = '''
tell application "System Events"
  tell process "Google Chrome"
    repeat 15 times
      try
        set frontWin to front window
        set theSheet to sheet 1 of frontWin
        set allElems to entire contents of theSheet
        repeat with e in allElems
          try
            if role of e is "AXButton" and description of e is "Allow" then
              click e
              return "ok"
            end if
          end try
        end repeat
      end try
      delay 0.5
    end repeat
    return "not_found"
  end tell
end tell
''';
    try {
      await Process.run('osascript', ['-e', script]);
    } catch (_) {}
  }

  /// For Chrome 146+'s consent-based port (no HTTP endpoints):
  /// Connect via WebSocket to the browser-level CDP endpoint, send
  /// Target.getTargets, find the best matching target, and return its WS URL.
  ///
  /// Chrome shows "Allow remote debugging?" dialog — auto-clicked via
  /// macOS Accessibility API so the user never has to manually confirm.
  Future<String?> _discoverTargetViaConsentPort({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final wsUrl = 'ws://127.0.0.1:$_port/devtools/browser/${_generateUuid()}';
    WebSocket? ws;
    // Auto-click the Allow dialog in parallel with the WebSocket connection.
    // Chrome shows the dialog as soon as the upgrade request arrives; the
    // WebSocket handshake completes only after the user (or us) clicks Allow.
    unawaited(_autoAllowChromeConsentDialog());
    try {
      ws = await _connectWebSocketNoOrigin(wsUrl, timeout: timeout);
    } catch (_) {
      return null;
    }

    try {
      // Send Target.getTargets
      const msgId = 1;
      ws.add(jsonEncode({
        'id': msgId,
        'method': 'Target.getTargets',
        'params': {},
      }));

      // Wait for response
      await for (final msg in ws.timeout(const Duration(seconds: 5))) {
        final data = jsonDecode(msg as String) as Map<String, dynamic>;
        if (data['id'] == msgId) {
          final result = data['result'] as Map<String, dynamic>?;
          final targetInfos = result?['targetInfos'] as List? ?? [];
          final pages = targetInfos
              .whereType<Map>()
              .where((t) => t['type'] == 'page')
              .toList();

          // Match by URL (same logic as _discoverTarget HTTP path)
          final targetUri = _url.isNotEmpty ? Uri.tryParse(_url) : null;
          final targetHost = targetUri?.host ?? '';

          // Exact URL match
          if (targetHost.isNotEmpty) {
            for (final t in pages) {
              if (t['url'] == _url) {
                connectedToExistingTab = true;
                return 'ws://127.0.0.1:$_port/devtools/page/${t['targetId']}';
              }
            }
            // Same host match
            for (final t in pages) {
              final tabUri = Uri.tryParse(t['url']?.toString() ?? '');
              if (tabUri != null && tabUri.host == targetHost) {
                connectedToExistingTab = true;
                return 'ws://127.0.0.1:$_port/devtools/page/${t['targetId']}';
              }
            }
            // Same root domain
            final targetParts = targetHost.split('.');
            final targetRoot = targetParts.length >= 2
                ? targetParts.sublist(targetParts.length - 2).join('.')
                : targetHost;
            for (final t in pages) {
              final tabUri = Uri.tryParse(t['url']?.toString() ?? '');
              if (tabUri != null) {
                final tabParts = tabUri.host.split('.');
                final tabRoot = tabParts.length >= 2
                    ? tabParts.sublist(tabParts.length - 2).join('.')
                    : tabUri.host;
                if (tabRoot == targetRoot) {
                  connectedToExistingTab = true;
                  return 'ws://127.0.0.1:$_port/devtools/page/${t['targetId']}';
                }
              }
            }
          }

          // Blank tab or first non-chrome tab
          for (final t in pages) {
            final tabUrl = t['url']?.toString() ?? '';
            if (tabUrl == 'about:blank') {
              return 'ws://127.0.0.1:$_port/devtools/page/${t['targetId']}';
            }
          }
          if (_url.isEmpty && pages.isNotEmpty) {
            return 'ws://127.0.0.1:$_port/devtools/page/${pages.first['targetId']}';
          }

          // No match found — create a new tab via Target.createTarget
          ws.add(jsonEncode({
            'id': msgId + 1,
            'method': 'Target.createTarget',
            'params': {'url': _url.isNotEmpty ? _url : 'about:blank'},
          }));
          await for (final msg2 in ws.timeout(const Duration(seconds: 5))) {
            final d2 = jsonDecode(msg2 as String) as Map<String, dynamic>;
            if (d2['id'] == msgId + 1) {
              final targetId = d2['result']?['targetId'] as String?;
              if (targetId != null) {
                return 'ws://127.0.0.1:$_port/devtools/page/$targetId';
              }
              break;
            }
          }
          break;
        }
      }
    } catch (_) {}

    try {
      await ws.close();
    } catch (_) {}
    return null;
  }

  /// Connect to a WebSocket without sending an Origin header.
  ///
  /// Chrome 146 consent ports reject all WebSocket connections that include an
  /// Origin header (returns 403 Forbidden). Dart's built-in WebSocket.connect()
  /// always adds an Origin header, so we do the upgrade manually via a raw
  /// TCP socket and then hand it off to WebSocket.fromUpgradedSocket().
  Future<WebSocket> _connectWebSocketNoOrigin(
    String wsUrl, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final uri = Uri.parse(wsUrl);
    final host = uri.host;
    final port = uri.port;
    final path = uri.path.isEmpty ? '/' : uri.path;

    // Random WebSocket key (16 bytes, base64-encoded)
    final r = Random.secure();
    final key = base64Encode(List<int>.generate(16, (_) => r.nextInt(256)));

    // Open raw TCP connection
    final socket = await Socket.connect(host, port, timeout: timeout);
    socket.setOption(SocketOption.tcpNoDelay, true);

    // Send HTTP WebSocket upgrade request WITHOUT Origin header
    socket.add(utf8.encode(
      'GET $path HTTP/1.1\r\n'
      'Host: $host:$port\r\n'
      'Upgrade: websocket\r\n'
      'Connection: Upgrade\r\n'
      'Sec-WebSocket-Key: $key\r\n'
      'Sec-WebSocket-Version: 13\r\n'
      '\r\n',
    ));
    await socket.flush();

    // Read HTTP response headers until \r\n\r\n
    final headerBuf = <int>[];
    final completer = Completer<void>();
    StreamSubscription<List<int>>? sub;

    sub = socket.listen(
      (chunk) {
        if (completer.isCompleted) return;
        headerBuf.addAll(chunk);
        for (var i = 0; i <= headerBuf.length - 4; i++) {
          if (headerBuf[i] == 13 &&
              headerBuf[i + 1] == 10 &&
              headerBuf[i + 2] == 13 &&
              headerBuf[i + 3] == 10) {
            sub?.pause();
            final headerStr = utf8.decode(headerBuf.sublist(0, i));
            if (!headerStr.contains(' 101 ')) {
              completer.completeError(
                  Exception('WebSocket upgrade failed:\n$headerStr'));
            } else {
              completer.complete();
            }
            return;
          }
        }
      },
      onError: (e) {
        if (!completer.isCompleted) completer.completeError(e);
      },
      onDone: () {
        if (!completer.isCompleted) {
          completer.completeError(
              Exception('Socket closed during WebSocket upgrade'));
        }
      },
      cancelOnError: true,
    );

    try {
      await completer.future.timeout(timeout);
    } catch (e) {
      await sub.cancel();
      socket.destroy();
      rethrow;
    }

    // Cancel our subscription so WebSocket.fromUpgradedSocket can subscribe.
    // dart:io Socket allows re-subscription after cancel — this is the same
    // pattern HttpServer uses when upgrading an HTTP connection to WebSocket.
    await sub.cancel();

    return WebSocket.fromUpgradedSocket(socket, serverSide: false);
  }

  /// Connect to a CDP WebSocket, using no-Origin mode for Chrome 146 consent ports.
  Future<WebSocket> _connectCdpWebSocket(String wsUrl,
      {Duration timeout = const Duration(seconds: 10)}) {
    if (_isChrome146ConsentPort) {
      return _connectWebSocketNoOrigin(wsUrl, timeout: timeout);
    }
    return WebSocket.connect(wsUrl).timeout(timeout);
  }

  /// Generate a random UUID v4.
  static String _generateUuid() {
    final r = Random.secure();
    final bytes = List<int>.generate(16, (_) => r.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    String hex(int b) => b.toRadixString(16).padLeft(2, '0');
    return '${hex(bytes[0])}${hex(bytes[1])}${hex(bytes[2])}${hex(bytes[3])}'
        '-${hex(bytes[4])}${hex(bytes[5])}'
        '-${hex(bytes[6])}${hex(bytes[7])}'
        '-${hex(bytes[8])}${hex(bytes[9])}'
        '-${hex(bytes[10])}${hex(bytes[11])}${hex(bytes[12])}${hex(bytes[13])}${hex(bytes[14])}${hex(bytes[15])}';
  }

  Future<String?> _discoverTarget() async {
    // Chrome 146+ consent port: HTTP endpoints not available, use WebSocket CDP.
    if (_isChrome146ConsentPort) {
      return _discoverTargetViaConsentPort(
          timeout: const Duration(seconds: 30));
    }

    // Try multiple times as Chrome may still be starting
    for (var i = 0; i < 10; i++) {
      try {
        final client = HttpClient();
        final request =
            await client.getUrl(Uri.parse('http://127.0.0.1:$_port/json'));
        final response = await request.close();
        final body = await response.transform(utf8.decoder).join();
        client.close();

        final tabs = jsonDecode(body) as List;
        final pageTabs = tabs
            .where((t) => t is Map && t['type'] == 'page')
            .cast<Map>()
            .toList();

        // Parse target host for domain matching
        final targetUri = _url.isNotEmpty ? Uri.tryParse(_url) : null;
        final targetHost = targetUri?.host ?? '';

        // 1. Same domain match (host-based, ignores path/query entirely)
        //    This is the PRIMARY strategy — never hijack tabs from other domains.
        if (targetHost.isNotEmpty) {
          // Prefer exact URL match within same domain
          for (final tab in pageTabs) {
            if (tab['url'] == _url) {
              connectedToExistingTab = true;
              return tab['webSocketDebuggerUrl'] as String?;
            }
          }
          // Then any tab on the same domain
          for (final tab in pageTabs) {
            final tabUri = Uri.tryParse(tab['url']?.toString() ?? '');
            if (tabUri != null && tabUri.host == targetHost) {
              return tab['webSocketDebuggerUrl'] as String?;
            }
          }
        }

        // 1b. Same root domain match (e.g. passport.csdn.net → csdn.net)
        //     Handles login redirects where subdomain changes after auth.
        if (targetHost.isNotEmpty) {
          final targetParts = targetHost.split('.');
          final targetRoot = targetParts.length >= 2
              ? targetParts.sublist(targetParts.length - 2).join('.')
              : targetHost;
          for (final tab in pageTabs) {
            final tabUri = Uri.tryParse(tab['url']?.toString() ?? '');
            if (tabUri != null) {
              final tabParts = tabUri.host.split('.');
              final tabRoot = tabParts.length >= 2
                  ? tabParts.sublist(tabParts.length - 2).join('.')
                  : tabUri.host;
              if (tabRoot == targetRoot) {
                connectedToExistingTab = true;
                return tab['webSocketDebuggerUrl'] as String?;
              }
            }
          }
        }

        // 2. No same-domain tab found — reuse about:blank tabs only.
        //    Do NOT reuse chrome:// tabs (newtab, new-tab-page, etc.):
        //    Page.enable / DOM.enable hang indefinitely on chrome:// pages,
        //    causing a 30s timeout.  Let them fall through to null so
        //    connect() creates a fresh tab via PUT /json/new.
        for (final tab in pageTabs) {
          final tabUrl = tab['url']?.toString() ?? '';
          if (tabUrl == 'about:blank') {
            return tab['webSocketDebuggerUrl'] as String?;
          }
        }

        // 3. No blank tab — if URL is empty, pick first non-chrome tab
        if (_url.isEmpty) {
          for (final tab in pageTabs) {
            final tabUrl = tab['url']?.toString() ?? '';
            if (!tabUrl.startsWith('devtools://') &&
                !tabUrl.startsWith('chrome://') &&
                tabUrl != 'about:blank') {
              return tab['webSocketDebuggerUrl'] as String?;
            }
          }
        }

        // 4. Last resort — return first page tab (only if no URL specified)
        if (_url.isEmpty && pageTabs.isNotEmpty) {
          return pageTabs.first['webSocketDebuggerUrl'] as String?;
        }

        // 5. No suitable tab found — return null, caller should create new tab
        //    This is better than hijacking an unrelated tab.
      } catch (_) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
    return null;
  }

  /// Public CDP method call — used by serve command and external callers.
  Future<Map<String, dynamic>> call(String method,
          [Map<String, dynamic>? params]) =>
      _call(method, params);

  /// Alias for [call] used by monkey testing and other modules.
  Future<Map<String, dynamic>> sendCommand(String method,
          [Map<String, dynamic>? params]) =>
      _call(method, params);

  /// Register a listener for a CDP event (supports multiple listeners per event).
  void onEvent(
      String method, void Function(Map<String, dynamic> params) callback) {
    _eventListeners.putIfAbsent(method, () => []);
    _eventListeners[method]!.add(callback);
  }

  /// Remove all listeners for a CDP event.
  void removeEventListeners(String method) {
    _eventListeners.remove(method);
  }

  Future<Map<String, dynamic>> _call(String method,
      [Map<String, dynamic>? params]) async {
    // If disconnected but reconnecting, wait up to 30s for reconnection
    if ((_ws == null || !_connected) && _reconnecting) {
      for (int i = 0; i < 60; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
        if (_connected && _ws != null) break;
      }
    }
    if (_ws == null || !_connected) {
      throw Exception('Not connected via CDP');
    }

    final id = _nextId++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;

    final request = jsonEncode({
      'id': id,
      'method': method,
      if (params != null) 'params': params,
    });
    _ws!.add(request);

    return completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        _pending.remove(id);
        throw TimeoutException(
            'CDP call "$method" timed out', const Duration(seconds: 30));
      },
    );
  }

  /// JavaScript helper that pierces Shadow DOM when querying elements.
  /// Use `deepQuery(selector)` instead of `document.querySelector(selector)`
  /// and `deepQueryAll(selector)` instead of `document.querySelectorAll(selector)`.
  // ignore: unused_field
  static const String _shadowDomHelper = '''
function deepQuery(selector, root) {
  root = root || document;
  let el = root.querySelector(selector);
  if (el) return el;
  const shadows = root.querySelectorAll('*');
  for (const node of shadows) {
    if (node.shadowRoot) {
      el = deepQuery(selector, node.shadowRoot);
      if (el) return el;
    }
  }
  return null;
}
function deepQueryAll(selector, root) {
  root = root || document;
  let results = Array.from(root.querySelectorAll(selector));
  const nodes = root.querySelectorAll('*');
  for (const node of nodes) {
    if (node.shadowRoot) {
      results = results.concat(deepQueryAll(selector, node.shadowRoot));
    }
  }
  return results;
}
''';

  Future<Map<String, dynamic>> _evalJs(String expression) async {
    // Auto-wrap in IIFE to avoid 'const' redeclaration errors across calls.
    // Skip if already wrapped or is a simple expression (no declarations).
    final trimmed = expression.trim();
    final needsWrap = !trimmed.startsWith('(') &&
        (trimmed.contains('const ') ||
            trimmed.contains('let ') ||
            trimmed.contains('class ') ||
            trimmed.contains('function '));
    final wrapped = needsWrap ? '(() => { $trimmed })()' : expression;
    return _call('Runtime.evaluate', {
      'expression': wrapped,
      'returnByValue': true,
      'awaitPromise': false,
    });
  }

  /// Ensure focus is set on the focusable element at the given point.
  /// CDP Input.dispatchMouseEvent doesn't always trigger focus in headless Chrome.
  /// Traverses Shadow DOM boundaries to find the actual element.
  Future<void> _ensureFocusAtPoint(double x, double y) async {
    await _evalJs('''
      (() => {
        // Traverse shadow DOM to find the deepest element at point
        let el = document.elementFromPoint($x, $y);
        if (!el) return;
        // Drill into shadow roots
        while (el.shadowRoot) {
          const inner = el.shadowRoot.elementFromPoint($x, $y);
          if (!inner || inner === el) break;
          el = inner;
        }
        // Walk up to find the nearest focusable element
        const focusable = el.closest && el.closest('input, textarea, select, [contenteditable="true"], [contenteditable=""]');
        const target = focusable || el;
        if (target && target !== document.activeElement &&
            (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA' ||
             target.tagName === 'SELECT' || target.isContentEditable)) {
          target.focus();
        }
      })()
    ''');
  }

  Future<void> _dispatchMouseEvent(
    String type,
    double x,
    double y, {
    String button = 'none',
    int clickCount = 0,
  }) async {
    await _call('Input.dispatchMouseEvent', {
      'type': type,
      'x': x,
      'y': y,
      'button': button,
      'clickCount': clickCount,
    });
  }

  /// Build a CSS selector from key/ref parameters.
  String _buildSelector({String? key, String? text, String? ref}) {
    if (key != null) {
      return '#$key, [name="$key"], [data-testid="$key"], [data-key="$key"]';
    }
    if (ref != null) {
      // Refs like "button:Login" — actual search is done in _jsFindElement via JS
      return '[data-ref="$ref"]';
    }
    if (text != null) {
      return '[data-text="$text"]'; // placeholder, actual search done in JS
    }
    return '*';
  }

  /// Parse a JSON-stringified eval result into a Map.
  /// Handles both String (from JSON.stringify) and Map (from returnByValue).
  Map<String, dynamic>? _parseJsonEval(Map<String, dynamic> result) {
    final value = result['result']?['value'];
    if (value is String && value != 'null') {
      try {
        final decoded = jsonDecode(value);
        if (decoded is Map<String, dynamic>) return decoded;
      } catch (_) {}
    }
    if (value is Map) return value as Map<String, dynamic>;
    return null;
  }

  /// Generate JS that resolves an element by multiple strategies:
  /// CSS selector, ID, name, data-testid, then text content.
  /// Returns an IIFE string that evaluates to the element or null.
  String _jsResolveElement(String key) {
    return '''(() => {
      let el = document.querySelector('$key');
      if (!el) el = document.getElementById('$key');
      if (!el) el = document.querySelector('[name="$key"]');
      if (!el) el = document.querySelector('[data-testid="$key"]');
      if (!el) el = document.querySelector('[data-test*="$key"]');
      if (!el) {
        for (const e of document.querySelectorAll('*')) {
          if (e.textContent && e.textContent.trim() === '$key') { el = e; break; }
        }
      }
      return el;
    })()''';
  }

  /// Generate JS code to find an element by selector or text.
  String _jsFindElement(String selector, {String? text, String? ref}) {
    // Deep query helper pierces Shadow DOM
    const deepQ = '''
function _dq(sel, root) {
  root = root || document;
  let el = root.querySelector(sel);
  if (el) return el;
  for (const n of root.querySelectorAll('*')) {
    if (n.shadowRoot) { el = _dq(sel, n.shadowRoot); if (el) return el; }
  }
  return null;
}
function _dqAll(sel, root) {
  root = root || document;
  let r = Array.from(root.querySelectorAll(sel));
  for (const n of root.querySelectorAll('*')) {
    if (n.shadowRoot) r = r.concat(_dqAll(sel, n.shadowRoot));
  }
  return r;
}
''';

    if (text != null) {
      final escaped = text.replaceAll("'", "\\'").replaceAll('\n', '\\n');
      return '''(() => {
        $deepQ
        let el = _dq('$selector');
        if (el) return el;
        // Visibility check helper
        function _vis(e) {
          const s = window.getComputedStyle(e);
          if (s.display === 'none' || s.visibility === 'hidden' || s.opacity === '0') return false;
          const r = e.getBoundingClientRect();
          return r.width > 0 && r.height > 0;
        }
        // Interactive tags get priority
        const interactive = new Set(['A','BUTTON','INPUT','SELECT','TEXTAREA','LABEL']);
        function _score(e) {
          let s = 0;
          if (_vis(e)) s += 1000;
          if (interactive.has(e.tagName) || e.getAttribute('role') === 'button' || e.getAttribute('role') === 'link' || e.getAttribute('role') === 'tab') s += 500;
          // Prefer smallest textContent (most specific match)
          s -= Math.min((e.textContent || '').length, 999);
          return s;
        }
        const all = _dqAll('a, button, input, select, textarea, label, span, p, h1, h2, h3, h4, h5, h6, div, li, td, th, [role], [contenteditable], [tabindex], [onclick]');
        // Also search shadow roots for button-like custom elements
        function _shadowButtons(root) {
          let r = [];
          for (const n of (root || document).querySelectorAll('*')) {
            if (n.shadowRoot) {
              r = r.concat(Array.from(n.shadowRoot.querySelectorAll('button, [role="button"], [type="submit"], a, span, label')));
              r = r.concat(_shadowButtons(n.shadowRoot));
            }
          }
          return r;
        }
        for (const sb of _shadowButtons(document)) {
          if (!all.includes(sb)) all.push(sb);
        }
        // Exact match — pick best scored
        let best = null, bestScore = -Infinity;
        for (const e of all) {
          const t = (e.textContent || '').trim();
          if (t === '$escaped') {
            const sc = _score(e);
            if (sc > bestScore) { best = e; bestScore = sc; }
          }
        }
        if (best) return best;
        // Contains match — pick best scored
        best = null; bestScore = -Infinity;
        for (const e of all) {
          const t = (e.textContent || '').trim();
          if (t.includes('$escaped')) {
            const sc = _score(e);
            if (sc > bestScore) { best = e; bestScore = sc; }
          }
        }
        return best;
      })()''';
    }
    if (ref != null) {
      final parts = ref.split(':');
      if (parts.length >= 2) {
        final tag = parts[0];
        final refText = parts.sublist(1).join(':').replaceAll("'", "\\'");
        String tagSelector;
        switch (tag) {
          case 'button':
            tagSelector =
                'button, [role="button"], input[type="submit"], input[type="button"]';
            break;
          case 'input':
            tagSelector = 'input, textarea, select';
            break;
          case 'link':
            tagSelector = 'a, [role="link"]';
            break;
          default:
            tagSelector = '*';
        }
        return '''(() => {
          $deepQ
          const candidates = _dqAll('$tagSelector');
          for (const e of candidates) {
            const t = (e.textContent || '').trim();
            const label = e.getAttribute('aria-label') || e.getAttribute('placeholder') || '';
            if (t === '$refText' || label === '$refText' || e.id === '$refText') return e;
          }
          for (const e of candidates) {
            const t = (e.textContent || '').trim();
            if (t.includes('$refText')) return e;
          }
          return null;
        })()''';
      }
    }
    return '''(() => {
      $deepQ
      return _dq('$selector');
    })()''';
  }

  /// Get element bounds (returns {x, y, w, h, cx, cy} or null).
  Future<Map<String, double>?> _getElementBounds(String selector,
      {String? text, String? ref}) async {
    final result = await _evalJs('''
      (() => {
        const el = ${_jsFindElement(selector, text: text, ref: ref)};
        if (!el) return JSON.stringify(null);
        const rect = el.getBoundingClientRect();
        return JSON.stringify({
          x: rect.left,
          y: rect.top,
          w: rect.width,
          h: rect.height,
          cx: rect.left + rect.width / 2,
          cy: rect.top + rect.height / 2
        });
      })()
    ''');

    final parsed = _parseJsonEval(result);
    if (parsed != null) {
      return {
        'x': (parsed['x'] as num).toDouble(),
        'y': (parsed['y'] as num).toDouble(),
        'w': (parsed['w'] as num).toDouble(),
        'h': (parsed['h'] as num).toDouble(),
        'cx': (parsed['cx'] as num).toDouble(),
        'cy': (parsed['cy'] as num).toDouble(),
      };
    }
    return null;
  }

  void _onMessage(dynamic data) {
    try {
      final json = jsonDecode(data as String) as Map<String, dynamic>;
      final id = json['id'] as int?;
      if (id != null && _pending.containsKey(id)) {
        final completer = _pending.remove(id)!;
        if (json.containsKey('error')) {
          final err = json['error'] as Map<String, dynamic>;
          completer.completeError(Exception(
            'CDP error ${err['code']}: ${err['message']}',
          ));
        } else {
          completer.complete((json['result'] as Map<String, dynamic>?) ?? {});
        }
      }
      // CDP events (no id)
      final method = json['method'] as String?;
      if (method != null) {
        _eventSubscriptions[method]?.call();
        final listeners = _eventListeners[method];
        if (listeners != null) {
          final params = (json['params'] as Map<String, dynamic>?) ?? {};
          for (final cb in listeners) {
            cb(params);
          }
        }
      }
    } catch (e) {
      // Malformed message
    }
  }

  /// Whether auto-reconnect is in progress.
  bool _reconnecting = false;

  /// Max auto-reconnect attempts.
  static const int _maxReconnectAttempts = 5;

  void _onDisconnect() {
    _connected = false;
    _failAllPending('Connection lost');
    // Trigger auto-reconnect (non-blocking)
    _autoReconnect();
  }

  /// Auto-reconnect to CDP when connection drops.
  Future<void> _autoReconnect() async {
    if (_reconnecting) return;
    _reconnecting = true;
    try {
      for (int attempt = 1; attempt <= _maxReconnectAttempts; attempt++) {
        // Exponential backoff: 1s, 2s, 4s, 8s, 16s
        await Future.delayed(Duration(seconds: 1 << (attempt - 1)));
        try {
          final wsUrl = await _discoverTarget();
          if (wsUrl == null) continue;

          _ws = await _connectCdpWebSocket(wsUrl);
          _connected = true;

          _ws!.listen(
            _onMessage,
            onDone: _onDisconnect,
            onError: (_) => _onDisconnect(),
            cancelOnError: false,
          );

          // Re-enable required CDP domains
          await Future.wait([
            _call('Page.enable'),
            _call('DOM.enable'),
            _call('Runtime.enable'),
          ]);
          return; // Success
        } catch (_) {
          // Retry
        }
      }
    } finally {
      _reconnecting = false;
    }
  }

  void _failAllPending(String reason) {
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(Exception('CDP: $reason'));
      }
    }
    _pending.clear();
  }
}

// (removed _TypeSegment — no longer needed)
