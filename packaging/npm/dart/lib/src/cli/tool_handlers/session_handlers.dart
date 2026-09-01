part of '../server.dart';

extension _SessionPersistenceHandlers on FlutterMcpServer {
  /// Session persistence tools (save/restore/diff).
  /// Returns null if the tool is not handled by this group.
  Future<dynamic> _handleSessionPersistenceTools(
      String name, Map<String, dynamic> args) async {
    switch (name) {
      case 'save_session':
        return _handleSaveSession(args);
      case 'restore_session':
        return _handleRestoreSession(args);
      case 'session_diff':
        return _handleSessionDiff(args);
      default:
        return null;
    }
  }

  CdpDriver _requireCdpForSession() {
    final cdp = _cdpDriver;
    if (cdp == null) {
      throw Exception('Session persistence requires an active CDP connection');
    }
    return cdp;
  }

  Future<Map<String, dynamic>> _handleSaveSession(
      Map<String, dynamic> args) async {
    final cdp = _requireCdpForSession();
    final path = args['path'] as String? ?? './.flutter-skill-session.json';

    try {
      // Get basic page info
      final cookiesJs = '''
(function() {
  return JSON.stringify({
    url: window.location.href,
    title: document.title,
    cookies: document.cookie,
  });
})()
''';
      final basicInfo = await cdp.eval(cookiesJs);
      final basicValue = basicInfo['result']?['value'] as String?;
      final basic = basicValue != null
          ? jsonDecode(basicValue) as Map<String, dynamic>
          : <String, dynamic>{};

      // Get localStorage
      final lsJs = '''
(function() {
  var data = {};
  for (var i = 0; i < localStorage.length; i++) {
    var key = localStorage.key(i);
    data[key] = localStorage.getItem(key);
  }
  return JSON.stringify(data);
})()
''';
      final lsResult = await cdp.eval(lsJs);
      final lsValue = lsResult['result']?['value'] as String?;
      final localStorage = lsValue != null
          ? jsonDecode(lsValue) as Map<String, dynamic>
          : <String, dynamic>{};

      // Get sessionStorage
      final ssJs = '''
(function() {
  var data = {};
  for (var i = 0; i < sessionStorage.length; i++) {
    var key = sessionStorage.key(i);
    data[key] = sessionStorage.getItem(key);
  }
  return JSON.stringify(data);
})()
''';
      final ssResult = await cdp.eval(ssJs);
      final ssValue = ssResult['result']?['value'] as String?;
      final sessionStorage = ssValue != null
          ? jsonDecode(ssValue) as Map<String, dynamic>
          : <String, dynamic>{};

      // Get full cookies via Network.getAllCookies if available
      Map<String, dynamic> networkCookies = {};
      try {
        networkCookies =
            await cdp.evaluate('1'); // Trigger to use getCookies method
        final cdpCookies = await cdp.getCookies();
        networkCookies = cdpCookies;
      } catch (_) {
        // Fallback to document.cookie
        networkCookies = {'document_cookies': basic['cookies'] ?? ''};
      }

      final session = {
        'version': 1,
        'saved_at': DateTime.now().toIso8601String(),
        'url': basic['url'] ?? '',
        'title': basic['title'] ?? '',
        'cookies': networkCookies,
        'local_storage': localStorage,
        'session_storage': sessionStorage,
      };

      final file = File(path);
      await file.parent.create(recursive: true);
      await file
          .writeAsString(const JsonEncoder.withIndent('  ').convert(session));

      return {
        'success': true,
        'path': path,
        'url': session['url'],
        'title': session['title'],
        'local_storage_keys': localStorage.keys.toList(),
        'session_storage_keys': sessionStorage.keys.toList(),
        'saved_at': session['saved_at'],
      };
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  Future<Map<String, dynamic>> _handleRestoreSession(
      Map<String, dynamic> args) async {
    final cdp = _requireCdpForSession();
    final path = args['path'] as String? ?? './.flutter-skill-session.json';

    try {
      final file = File(path);
      if (!await file.exists()) {
        return {'success': false, 'error': 'Session file not found: $path'};
      }

      final content = await file.readAsString();
      final session = jsonDecode(content) as Map<String, dynamic>;

      final url = session['url'] as String? ?? '';
      final localStorage =
          (session['local_storage'] as Map<String, dynamic>?) ?? {};
      final sessionStorage =
          (session['session_storage'] as Map<String, dynamic>?) ?? {};
      final cookies = session['cookies'] as Map<String, dynamic>?;

      // Navigate to the saved URL
      if (url.isNotEmpty) {
        await cdp.navigate(url);
        // Wait for page load
        await Future.delayed(const Duration(seconds: 2));
      }

      // Restore cookies
      if (cookies != null) {
        if (cookies.containsKey('cookies') && cookies['cookies'] is List) {
          // Full cookie objects from Network.getAllCookies
          for (final cookie in cookies['cookies'] as List) {
            final c = cookie as Map<String, dynamic>;
            try {
              await cdp.setCookie(
                c['name'] as String? ?? '',
                c['value'] as String? ?? '',
                domain: c['domain'] as String?,
                path: c['path'] as String?,
              );
            } catch (_) {}
          }
        } else if (cookies.containsKey('document_cookies')) {
          // Simple document.cookie format
          final cookieStr = cookies['document_cookies'] as String? ?? '';
          if (cookieStr.isNotEmpty) {
            await cdp.eval('document.cookie = ${jsonEncode(cookieStr)}');
          }
        }
      }

      // Restore localStorage
      if (localStorage.isNotEmpty) {
        final lsJson = jsonEncode(localStorage);
        await cdp.eval('''
(function() {
  var data = $lsJson;
  for (var key in data) {
    localStorage.setItem(key, data[key]);
  }
})()
''');
      }

      // Restore sessionStorage
      if (sessionStorage.isNotEmpty) {
        final ssJson = jsonEncode(sessionStorage);
        await cdp.eval('''
(function() {
  var data = $ssJson;
  for (var key in data) {
    sessionStorage.setItem(key, data[key]);
  }
})()
''');
      }

      // Reload to apply cookies and storage
      await cdp.eval('location.reload()');
      await Future.delayed(const Duration(seconds: 2));

      return {
        'success': true,
        'restored_url': url,
        'restored_local_storage_keys': localStorage.keys.toList(),
        'restored_session_storage_keys': sessionStorage.keys.toList(),
        'session_saved_at': session['saved_at'],
      };
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  Future<Map<String, dynamic>> _handleSessionDiff(
      Map<String, dynamic> args) async {
    final pathA = args['path_a'] as String?;
    final pathB = args['path_b'] as String?;

    if (pathA == null || pathB == null) {
      return {'success': false, 'error': 'path_a and path_b are required'};
    }

    try {
      final fileA = File(pathA);
      final fileB = File(pathB);

      if (!await fileA.exists()) {
        return {'success': false, 'error': 'File not found: $pathA'};
      }
      if (!await fileB.exists()) {
        return {'success': false, 'error': 'File not found: $pathB'};
      }

      final sessionA =
          jsonDecode(await fileA.readAsString()) as Map<String, dynamic>;
      final sessionB =
          jsonDecode(await fileB.readAsString()) as Map<String, dynamic>;

      final differences = <Map<String, dynamic>>[];

      // Compare URL
      if (sessionA['url'] != sessionB['url']) {
        differences.add({
          'field': 'url',
          'a': sessionA['url'],
          'b': sessionB['url'],
        });
      }

      // Compare title
      if (sessionA['title'] != sessionB['title']) {
        differences.add({
          'field': 'title',
          'a': sessionA['title'],
          'b': sessionB['title'],
        });
      }

      // Compare localStorage
      final lsA = (sessionA['local_storage'] as Map<String, dynamic>?) ?? {};
      final lsB = (sessionB['local_storage'] as Map<String, dynamic>?) ?? {};
      final allLsKeys = {...lsA.keys, ...lsB.keys};
      for (final key in allLsKeys) {
        if (lsA[key] != lsB[key]) {
          differences.add({
            'field': 'local_storage.$key',
            'a': lsA[key],
            'b': lsB[key],
          });
        }
      }

      // Compare sessionStorage
      final ssA = (sessionA['session_storage'] as Map<String, dynamic>?) ?? {};
      final ssB = (sessionB['session_storage'] as Map<String, dynamic>?) ?? {};
      final allSsKeys = {...ssA.keys, ...ssB.keys};
      for (final key in allSsKeys) {
        if (ssA[key] != ssB[key]) {
          differences.add({
            'field': 'session_storage.$key',
            'a': ssA[key],
            'b': ssB[key],
          });
        }
      }

      // Compare cookies (simplified)
      final cookiesA = jsonEncode(sessionA['cookies'] ?? {});
      final cookiesB = jsonEncode(sessionB['cookies'] ?? {});
      if (cookiesA != cookiesB) {
        differences.add({
          'field': 'cookies',
          'changed': true,
          'a_summary': '${(sessionA['cookies'] as Map?)?.length ?? 0} entries',
          'b_summary': '${(sessionB['cookies'] as Map?)?.length ?? 0} entries',
        });
      }

      return {
        'success': true,
        'path_a': pathA,
        'path_b': pathB,
        'saved_at_a': sessionA['saved_at'],
        'saved_at_b': sessionB['saved_at'],
        'total_differences': differences.length,
        'differences': differences,
        'identical': differences.isEmpty,
      };
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }
}
