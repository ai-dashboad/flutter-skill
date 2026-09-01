part of '../server.dart';

extension _AuthHandlers on FlutterMcpServer {
  /// Authentication tools
  /// Returns null if the tool is not handled.
  Future<dynamic> _handleAuthTools(
      String name, Map<String, dynamic> args) async {
    if (name == 'auth_biometric') {
      final action = args['action'] as String? ?? '';
      if (action.isEmpty)
        return {
          "success": false,
          "error": "Missing required parameter: action (enroll|match|fail)"
        };
      final platform = await _detectSimulatorPlatform();
      String command;
      if (platform == 'ios') {
        // iOS biometric uses notifyutil via simctl spawn
        switch (action) {
          case 'enroll':
            command =
                'xcrun simctl spawn booted notifyutil -s com.apple.BiometricKit.enrollmentChanged 1';
            break;
          case 'match':
            command =
                'xcrun simctl spawn booted notifyutil -p com.apple.BiometricKit.pearl.match';
            break;
          case 'fail':
            command =
                'xcrun simctl spawn booted notifyutil -p com.apple.BiometricKit.pearl.nomatch';
            break;
          default:
            return {"success": false, "error": "Invalid action: $action"};
        }
      } else {
        switch (action) {
          case 'enroll':
          case 'match':
            command = '${_findAdb()} -s emulator-5554 emu finger touch 1';
            break;
          case 'fail':
            command = '${_findAdb()} -s emulator-5554 emu finger touch 0';
            break;
          default:
            return {"success": false, "error": "Invalid action: $action"};
        }
      }
      try {
        final result = await Process.run('sh', ['-c', command]);
        return {
          "success": result.exitCode == 0,
          "platform": platform,
          "action": action
        };
      } catch (e) {
        return {"success": false, "error": e.toString()};
      }
    }

    if (name == 'auth_otp') {
      final secret = args['secret'] as String?;
      if (secret != null) {
        final digits = args['digits'] as int? ?? 6;
        final period = args['period'] as int? ?? 30;
        final code = _generateTotp(secret, digits, period);
        final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        final validFor = period - (now % period);
        return {"code": code, "valid_for_seconds": validFor};
      }
      // Read clipboard
      final platform = await _detectSimulatorPlatform();
      try {
        if (platform == 'ios') {
          final result =
              await Process.run('xcrun', ['simctl', 'pbpaste', 'booted']);
          return {
            "clipboard": result.stdout.toString().trim(),
            "platform": "ios"
          };
        } else {
          final result = await Process.run(
              _findAdb(), ['shell', 'service', 'call', 'clipboard', '1']);
          return {
            "clipboard": result.stdout.toString().trim(),
            "platform": "android"
          };
        }
      } catch (e) {
        return {"success": false, "error": e.toString()};
      }
    }

    if (name == 'auth_deeplink') {
      final url = args['url'] as String;
      final platform = await _detectSimulatorPlatform();
      try {
        if (platform == 'web') {
          // For web/electron/tauri: navigate via eval
          final client = _getClient(args);
          if (client is BridgeDriver) {
            try {
              await client.callMethod(
                  'eval', {'expression': "window.location.href='$url'"});
              return {
                "success": true,
                "url": url,
                "platform": platform,
                "method": "eval"
              };
            } catch (_) {}
          }
          return {
            "success": false,
            "url": url,
            "platform": platform,
            "note": "Cannot open deep link on web platform without eval support"
          };
        }
        ProcessResult result;
        if (platform == 'ios') {
          result =
              await Process.run('xcrun', ['simctl', 'openurl', 'booted', url]);
        } else {
          result = await Process.run(_findAdb(), [
            'shell',
            'am',
            'start',
            '-a',
            'android.intent.action.VIEW',
            '-d',
            url
          ]);
        }
        return {
          "success": result.exitCode == 0,
          "url": url,
          "platform": platform
        };
      } catch (e) {
        return {"success": false, "error": e.toString()};
      }
    }

    // Recording tools

    if (name == 'auth_inject_session') {
      final token = args['token'] as String;
      final key = args['key'] as String? ?? 'auth_token';
      final storageType =
          args['storage_type'] as String? ?? 'shared_preferences';
      // Detect platform from active connection
      final platform = await _detectSimulatorPlatform();

      // For web/electron/tauri: inject via JavaScript
      if (storageType == 'cookie' ||
          storageType == 'local_storage' ||
          platform == 'web') {
        final js = storageType == 'cookie'
            ? "document.cookie='$key=$token; path=/'"
            : "window.localStorage.setItem('$key','$token')";
        // If connected to a bridge with eval support, execute directly
        final client = _getClient(args);
        if (client is BridgeDriver) {
          try {
            final evalResult =
                await client.callMethod('eval', {'expression': js});
            return {
              "success": true,
              "storage_type": storageType,
              "key": key,
              "platform": platform,
              "injected": true,
              "eval_result": evalResult
            };
          } catch (_) {
            // Fall back to returning snippet
          }
        }
        return {
          "success": true,
          "storage_type": storageType,
          "key": key,
          "js_snippet": js,
          "platform": platform,
          "note": "Execute this JS in your web app's console"
        };
      }
      // For shared_preferences on mobile: provide instruction
      try {
        return {
          "success": true,
          "storage_type": storageType,
          "key": key,
          "token": token,
          "platform": platform,
          "note":
              "Token prepared for injection. Use hot_restart to pick up changes."
        };
      } catch (e) {
        return {"success": false, "error": e.toString()};
      }
    }

    if (name == 'qr_login_start') {
      return _handleQrLoginStart(args);
    }

    if (name == 'qr_login_wait') {
      return _handleQrLoginWait(args);
    }

    // Platform-agnostic tools that work on any connection type

    return null; // Not handled by this group
  }

  /// Detect and screenshot a QR code on the current page.
  /// Returns base64 image that can be sent to user for scanning.
  Future<Map<String, dynamic>> _handleQrLoginStart(
      Map<String, dynamic> args) async {
    final client = _getClient(args);
    if (client is! CdpDriver) {
      return {'success': false, 'error': 'qr_login requires CDP connection'};
    }

    final selector = args['selector'] as String?;
    final fullPage = args['full_page'] as bool? ?? false;

    // Step 1: Try to find QR code element
    String? qrBase64;

    if (!fullPage) {
      // Auto-detect QR code: look for common QR containers
      final detectJs = selector != null
          ? '''
        (() => {
          const el = document.querySelector(${jsonEncode(selector)});
          if (!el) return null;
          const r = el.getBoundingClientRect();
          return { x: r.x, y: r.y, width: r.width, height: r.height };
        })()
        '''
          : '''
        (() => {
          // Common QR code selectors across platforms
          const selectors = [
            'img[src*="qr"]', 'img[alt*="qr"]', 'img[alt*="QR"]',
            'img[src*="QR"]', 'img[class*="qr"]', 'img[class*="QR"]',
            'canvas[class*="qr"]', 'canvas[class*="QR"]',
            '[class*="qrcode"]', '[class*="QRCode"]', '[class*="qr-code"]',
            '[id*="qr"]', '[id*="QR"]',
            'img[src*="login"]canvas',
            // WeChat/CSDN/Zhihu specific
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
          // Fallback: find any square-ish image > 100px
          for (const img of document.querySelectorAll('img, canvas')) {
            const r = img.getBoundingClientRect();
            if (r.width > 100 && r.height > 100 && Math.abs(r.width - r.height) < 30) {
              return { x: r.x, y: r.y, width: r.width, height: r.height, selector: 'auto-square' };
            }
          }
          return null;
        })()
        ''';

      final detectResult = await client.evaluate(detectJs);
      final qrRect = detectResult['result']?['value'];

      if (qrRect is Map) {
        // Take region screenshot of QR code
        final x = (qrRect['x'] as num).toDouble();
        final y = (qrRect['y'] as num).toDouble();
        final w = (qrRect['width'] as num).toDouble();
        final h = (qrRect['height'] as num).toDouble();

        // Add some padding
        final pad = 10.0;
        qrBase64 = await client.takeRegionScreenshot(
          (x - pad).clamp(0, double.infinity),
          (y - pad).clamp(0, double.infinity),
          w + pad * 2,
          h + pad * 2,
        );

        if (qrBase64 != null) {
          // Record initial state for wait detection
          final urlResult = await client.evaluate('window.location.href');
          final currentUrl = urlResult['result']?['value']?.toString() ?? '';

          final cookieResult = await client.evaluate('document.cookie.length');
          final cookieLen = cookieResult['result']?['value'] ?? 0;

          return {
            'success': true,
            'qr_image': qrBase64,
            'format': 'jpeg',
            'qr_bounds': {
              'x': x,
              'y': y,
              'width': w,
              'height': h,
            },
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
    qrBase64 = await client.takeScreenshot(quality: 0.9);
    if (qrBase64 == null) {
      return {'success': false, 'error': 'Failed to take screenshot'};
    }

    final urlResult = await client.evaluate('window.location.href');
    final currentUrl = urlResult['result']?['value']?.toString() ?? '';
    final cookieResult = await client.evaluate('document.cookie.length');
    final cookieLen = cookieResult['result']?['value'] ?? 0;

    return {
      'success': true,
      'qr_image': qrBase64,
      'format': 'jpeg',
      'full_page': true,
      'initial_url': currentUrl,
      'initial_cookie_length': cookieLen,
      'hint':
          'QR element not auto-detected; returning full page screenshot. Send to user for scanning, then call qr_login_wait.',
    };
  }

  /// Poll until QR login succeeds (URL change, cookie change, QR disappears, or success text).
  Future<Map<String, dynamic>> _handleQrLoginWait(
      Map<String, dynamic> args) async {
    final client = _getClient(args);
    if (client is! CdpDriver) {
      return {'success': false, 'error': 'qr_login requires CDP connection'};
    }

    final timeoutMs = args['timeout_ms'] as int? ?? 120000; // 2min default
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
        // Check 1: URL changed
        final urlResult = await client.evaluate('window.location.href');
        final currentUrl = urlResult['result']?['value']?.toString() ?? '';

        if (initialUrl != null && currentUrl != initialUrl) {
          // URL changed — likely redirected after login
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

        // Check 2: Cookie length changed significantly
        final cookieResult = await client.evaluate('document.cookie.length');
        final currentCookieLen =
            (cookieResult['result']?['value'] as int?) ?? 0;
        if (currentCookieLen > initialCookieLen + 20) {
          return {
            'success': true,
            'method': 'cookie_changed',
            'cookie_length_delta': currentCookieLen - initialCookieLen,
            'url': currentUrl,
            'waited_ms': sw.elapsedMilliseconds,
          };
        }

        // Check 3: QR element disappeared
        if (qrSelector != null) {
          final qrCheck = await client.evaluate(
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

        // Check 4: Success text appeared
        if (successText != null) {
          final textCheck = await client.evaluate(
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
        // Connection might have broken during redirect — that could be success
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
}
