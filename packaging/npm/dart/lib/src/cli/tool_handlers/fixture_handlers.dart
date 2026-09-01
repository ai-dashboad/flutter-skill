part of '../server.dart';

extension _FixtureHandlers on FlutterMcpServer {
  Future<dynamic> _handleFixtureTools(
      String name, Map<String, dynamic> args) async {
    switch (name) {
      case 'fixture_load':
        return await _fixtureLoad(args);
      case 'fixture_reset':
        return await _fixtureReset(args);
      case 'fixture_switch_user':
        return await _fixtureSwitchUser(args);
      case 'fixture_switch_env':
        return await _fixtureSwitchEnv(args);
      default:
        return null;
    }
  }

  /// Load test fixture data into the app.
  Future<Map<String, dynamic>> _fixtureLoad(Map<String, dynamic> args) async {
    final type = args['type'] as String? ?? 'localStorage';
    final data = args['data'] as Map<String, dynamic>?;
    final url = args['url'] as String?;
    final filePath = args['file_path'] as String?;

    switch (type) {
      case 'api':
        if (url == null) {
          return {'success': false, 'error': 'url is required for api type'};
        }
        try {
          final bodyData = data ?? {};
          if (filePath != null) {
            final file = File(filePath);
            if (file.existsSync()) {
              final fileContent = jsonDecode(await file.readAsString());
              if (fileContent is Map) {
                bodyData.addAll(Map<String, dynamic>.from(fileContent));
              }
            }
          }
          final response = await http.post(
            Uri.parse(url),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(bodyData),
          );
          return {
            'success': response.statusCode >= 200 && response.statusCode < 300,
            'status_code': response.statusCode,
            'response': response.body.length < 1000
                ? response.body
                : '${response.body.substring(0, 1000)}...',
          };
        } catch (e) {
          return {'success': false, 'error': 'API call failed: $e'};
        }

      case 'localStorage':
        final cdp = _cdpDriver;
        if (cdp == null || !cdp.isConnected) {
          return {'success': false, 'error': 'CDP not connected'};
        }
        Map<String, dynamic> injectData = data ?? {};
        if (filePath != null) {
          final file = File(filePath);
          if (file.existsSync()) {
            final fileContent = jsonDecode(await file.readAsString());
            if (fileContent is Map) {
              injectData.addAll(Map<String, dynamic>.from(fileContent));
            }
          }
        }
        if (injectData.isEmpty) {
          return {'success': false, 'error': 'No data to inject'};
        }
        final jsEntries = injectData.entries
            .map((e) =>
                "localStorage.setItem('${_escapeJs(e.key)}', '${_escapeJs(jsonEncode(e.value))}')")
            .join(';');
        await cdp.eval(jsEntries);
        return {
          'success': true,
          'type': 'localStorage',
          'keys_set': injectData.keys.toList(),
        };

      case 'cookies':
        final cdp = _cdpDriver;
        if (cdp == null || !cdp.isConnected) {
          return {'success': false, 'error': 'CDP not connected'};
        }
        if (data == null || data.isEmpty) {
          return {'success': false, 'error': 'data is required for cookies'};
        }
        // Get current URL domain for cookies
        final currentUrlResult = await cdp.eval('window.location.hostname');
        final domain =
            (currentUrlResult['result']?['value'] as String?) ?? 'localhost';

        for (final entry in data.entries) {
          await cdp.sendCommand('Network.setCookie', {
            'name': entry.key,
            'value': entry.value.toString(),
            'domain': domain,
            'path': '/',
          });
        }
        return {
          'success': true,
          'type': 'cookies',
          'cookies_set': data.keys.toList(),
          'domain': domain,
        };

      case 'file':
        if (filePath == null) {
          return {
            'success': false,
            'error': 'file_path is required for file type'
          };
        }
        final file = File(filePath);
        if (!file.existsSync()) {
          return {'success': false, 'error': 'File not found: $filePath'};
        }
        final fileContent = jsonDecode(await file.readAsString());
        // Inject into localStorage
        return await _fixtureLoad({
          'type': 'localStorage',
          'data': fileContent is Map
              ? Map<String, dynamic>.from(fileContent)
              : {'data': fileContent},
        });

      default:
        return {'success': false, 'error': 'Unknown fixture type: $type'};
    }
  }

  /// Reset app to clean state.
  Future<Map<String, dynamic>> _fixtureReset(Map<String, dynamic> args) async {
    final resetApiUrl = args['reset_api_url'] as String?;
    final clearStorage = args['clear_storage'] as bool? ?? true;
    final clearCookies = args['clear_cookies'] as bool? ?? true;
    final clearCache = args['clear_cache'] as bool? ?? true;

    final cleared = <String>[];

    final cdp = _cdpDriver;
    if (cdp != null && cdp.isConnected) {
      if (clearStorage) {
        await cdp.eval('localStorage.clear(); sessionStorage.clear();');
        cleared.add('localStorage');
        cleared.add('sessionStorage');
      }

      if (clearCookies) {
        await cdp.sendCommand('Network.clearBrowserCookies', {});
        cleared.add('cookies');
      }

      if (clearCache) {
        await cdp.sendCommand('Network.clearBrowserCache', {});
        cleared.add('cache');
      }
    }

    // Call reset API if provided
    if (resetApiUrl != null) {
      try {
        final response = await http.post(Uri.parse(resetApiUrl));
        cleared.add('api_reset (status: ${response.statusCode})');
      } catch (e) {
        return {
          'success': false,
          'error': 'Reset API call failed: $e',
          'cleared': cleared,
        };
      }
    }

    return {
      'success': true,
      'cleared': cleared,
    };
  }

  /// Switch user role/account.
  Future<Map<String, dynamic>> _fixtureSwitchUser(
      Map<String, dynamic> args) async {
    final cdp = _cdpDriver;
    if (cdp == null || !cdp.isConnected) {
      return {'success': false, 'error': 'CDP not connected'};
    }

    final role = args['role'] as String? ?? 'user';
    final credentials = args['credentials'] as Map<String, dynamic>? ?? {};
    final loginUrl = args['login_url'] as String?;
    final usernameField = args['username_field'] as String? ?? 'email';
    // passwordField reserved for future use
    // final passwordField = args['password_field'] as String? ?? 'password';
    final submitButton = args['submit_button'] as String? ?? 'Sign In';

    // If token is provided, inject it directly
    final token = credentials['token'] as String?;
    if (token != null) {
      await cdp
          .eval("localStorage.setItem('auth_token', '${_escapeJs(token)}')");
      await cdp.eval('location.reload()');
      await Future.delayed(const Duration(seconds: 2));
      return {
        'success': true,
        'role': role,
        'method': 'token_injection',
      };
    }

    // Navigate to login page
    if (loginUrl != null) {
      await cdp.navigate(loginUrl);
      await Future.delayed(const Duration(seconds: 2));
    }

    final username = credentials['username'] as String?;
    final password = credentials['password'] as String?;

    if (username == null || password == null) {
      return {
        'success': false,
        'error':
            'credentials.username and credentials.password are required (or provide credentials.token)',
      };
    }

    // Fill in credentials
    try {
      // Try to find and fill username field
      await cdp.eval('''
        (() => {
          const fields = document.querySelectorAll('input');
          for (const f of fields) {
            const name = (f.name || f.id || f.type || '').toLowerCase();
            const placeholder = (f.placeholder || '').toLowerCase();
            const label = f.labels?.[0]?.textContent?.toLowerCase() || '';
            if (name.includes('${_escapeJs(usernameField)}') ||
                placeholder.includes('${_escapeJs(usernameField)}') ||
                label.includes('${_escapeJs(usernameField)}') ||
                name.includes('email') || f.type === 'email') {
              f.focus();
              f.value = '${_escapeJs(username)}';
              f.dispatchEvent(new Event('input', {bubbles: true}));
              f.dispatchEvent(new Event('change', {bubbles: true}));
              break;
            }
          }
        })()
      ''');

      // Fill password field
      await cdp.eval('''
        (() => {
          const fields = document.querySelectorAll('input[type="password"], input[name*="password"], input[id*="password"]');
          if (fields.length > 0) {
            const f = fields[0];
            f.focus();
            f.value = '${_escapeJs(password)}';
            f.dispatchEvent(new Event('input', {bubbles: true}));
            f.dispatchEvent(new Event('change', {bubbles: true}));
          }
        })()
      ''');

      // Click submit button
      await cdp.eval('''
        (() => {
          const buttons = document.querySelectorAll('button, input[type="submit"], [role="button"]');
          for (const b of buttons) {
            const text = (b.textContent || b.value || '').trim();
            if (text.toLowerCase().includes('${_escapeJs(submitButton.toLowerCase())}') ||
                text.toLowerCase().includes('log in') ||
                text.toLowerCase().includes('sign in') ||
                b.type === 'submit') {
              b.click();
              break;
            }
          }
        })()
      ''');

      // Wait for navigation to complete
      await Future.delayed(const Duration(seconds: 3));

      return {
        'success': true,
        'role': role,
        'method': 'form_login',
        'username': username,
      };
    } catch (e) {
      return {
        'success': false,
        'error': 'Login form interaction failed: $e',
      };
    }
  }

  /// Switch test environment.
  Future<Map<String, dynamic>> _fixtureSwitchEnv(
      Map<String, dynamic> args) async {
    final cdp = _cdpDriver;
    if (cdp == null || !cdp.isConnected) {
      return {'success': false, 'error': 'CDP not connected'};
    }

    final env = args['env'] as String?;
    if (env == null) {
      return {'success': false, 'error': 'env is required'};
    }

    final baseUrl = args['base_url'] as String?;
    final envVars = args['env_vars'] as Map<String, dynamic>?;

    // Inject environment variables into localStorage
    await cdp
        .eval("localStorage.setItem('flutter_skill_env', '${_escapeJs(env)}')");

    if (envVars != null) {
      for (final entry in envVars.entries) {
        await cdp.eval(
            "localStorage.setItem('${_escapeJs(entry.key)}', '${_escapeJs(jsonEncode(entry.value))}')");
      }
    }

    // Navigate to the new base URL if provided
    if (baseUrl != null) {
      await cdp.navigate(baseUrl);
      await Future.delayed(const Duration(seconds: 2));
    } else {
      // Just reload current page
      await cdp.eval('location.reload()');
      await Future.delayed(const Duration(seconds: 2));
    }

    return {
      'success': true,
      'env': env,
      if (baseUrl != null) 'base_url': baseUrl,
      if (envVars != null) 'env_vars_set': envVars.keys.toList(),
    };
  }

  // --- Helpers ---

  String _escapeJs(String s) {
    return s
        .replaceAll('\\', '\\\\')
        .replaceAll("'", "\\'")
        .replaceAll('\n', '\\n')
        .replaceAll('\r', '\\r');
  }
}
