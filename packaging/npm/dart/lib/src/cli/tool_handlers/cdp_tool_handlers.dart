part of '../server.dart';

extension _CdpToolHandlers on FlutterMcpServer {
  /// Execute a tool via CDP driver
  Future<dynamic> _executeCdpTool(
      String name, Map<String, dynamic> args, CdpDriver cdp) async {
    switch (name) {
      case 'inspect':
        final elements = await cdp.getInteractiveElements();
        final currentPageOnly = args['current_page_only'] ?? true;
        if (currentPageOnly) {
          return elements.where((e) {
            if (e is! Map) return true;
            final bounds = e['bounds'];
            if (bounds == null) return true;
            return (bounds['x'] as int? ?? 0) >= -10 &&
                (bounds['y'] as int? ?? 0) >= -10;
          }).toList();
        }
        return elements;

      case 'inspect_interactive':
        return await cdp.getInteractiveElementsStructured();

      case 'snapshot':
        // Use Accessibility Tree for compact, semantic snapshot (like Playwright)
        final mode = args['mode'] as String? ?? 'accessibility';
        if (mode == 'dom') {
          // Legacy DOM-based snapshot
          final structured = await cdp.getInteractiveElementsStructured();
          final elements = structured['elements'] as List<dynamic>? ?? [];
          final buffer = StringBuffer();
          for (var i = 0; i < elements.length; i++) {
            final el = elements[i] as Map<String, dynamic>;
            final isLast = i == elements.length - 1;
            final prefix = isLast ? '└── ' : '├── ';
            final ref = el['ref'] ?? '';
            final text = (el['text'] ?? el['label'] ?? '').toString();
            final displayText =
                text.length > 40 ? '${text.substring(0, 37)}...' : text;
            final bounds = el['bounds'] as Map<String, dynamic>?;
            final bStr = bounds != null
                ? '(${bounds['x']},${bounds['y']} ${bounds['w']}x${bounds['h']})'
                : '';
            final valuePart =
                (el['value'] != null && el['value'].toString().isNotEmpty)
                    ? ' value="${el['value']}"'
                    : '';
            final enabledPart = el['enabled'] == false ? ' DISABLED' : '';
            final actions = (el['actions'] as List?)?.join(',') ?? '';
            buffer.writeln(
                '$prefix[$ref] "$displayText" $bStr$valuePart$enabledPart {$actions}');
          }
          return {
            'snapshot': buffer.toString(),
            'mode': 'dom',
            'summary': structured['summary'] ?? '',
            'elementCount': elements.length,
            'interactiveCount': elements.length,
            'tokenEstimate': buffer.length ~/ 4,
            'hint':
                'Use ref IDs to interact: tap(ref: "button:Login"), enter_text(ref: "input:Email", text: "...")',
          };
        }
        // Default: Accessibility tree snapshot
        return await cdp.getAccessibilitySnapshot();

      case 'act':
        return await cdp.act(
          ref: args['ref'] as String?,
          text: args['text'] as String?,
          key: args['key'] as String?,
          action: args['action'] as String? ?? 'click',
          value: args['value'] as String?,
          timeoutMs: (args['timeout'] as num?)?.toInt() ?? 5000,
          dispatchRealEvents: args['dispatchRealEvents'] as bool? ?? false,
        );

      case 'tap':
        final x = args['x'] as num?;
        final y = args['y'] as num?;
        if (x != null && y != null) {
          await cdp.tapAt(x.toDouble(), y.toDouble());
          return {
            "success": true,
            "method": "coordinates",
            "position": {"x": x, "y": y}
          };
        }
        return await cdp.tap(
            key: args['key'], text: args['text'], ref: args['ref']);

      case 'enter_text':
        return await cdp.enterText(args['key'], args['text'], ref: args['ref']);

      case 'screenshot':
        final quality = (args['quality'] as num?)?.toDouble() ?? 0.8;
        final saveToFile = args['save_to_file'] ?? false;
        final imageBase64 = await cdp.takeScreenshot(quality: quality);
        if (imageBase64 == null) {
          return {"success": false, "error": "Failed to capture screenshot"};
        }
        if (saveToFile) {
          final timestamp = DateTime.now().millisecondsSinceEpoch;
          final file = File(
              '${Directory.systemTemp.path}/flutter_skill_screenshot_$timestamp.jpg');
          final bytes = base64.decode(imageBase64);
          await file.writeAsBytes(bytes);
          return {
            "success": true,
            "file_path": file.path,
            "size_bytes": bytes.length,
            "format": "jpeg"
          };
        }
        return {"image": imageBase64, "quality": quality};

      case 'screenshot_region':
        final x = (args['x'] as num).toDouble();
        final y = (args['y'] as num).toDouble();
        final width = (args['width'] as num).toDouble();
        final height = (args['height'] as num).toDouble();
        final saveToFile = args['save_to_file'] ?? false;
        final image = await cdp.takeRegionScreenshot(x, y, width, height);
        if (image == null)
          return {
            "success": false,
            "error": "Failed to capture region screenshot"
          };
        if (saveToFile) {
          final timestamp = DateTime.now().millisecondsSinceEpoch;
          final file = File(
              '${Directory.systemTemp.path}/flutter_skill_region_$timestamp.jpg');
          final bytes = base64.decode(image);
          await file.writeAsBytes(bytes);
          return {
            "success": true,
            "file_path": file.path,
            "size_bytes": bytes.length,
            "region": {"x": x, "y": y, "width": width, "height": height}
          };
        }
        return {"success": true, "image": image};

      case 'screenshot_element':
        final key = args['selector'] as String? ??
            args['key'] as String? ??
            args['text'] as String?;
        if (key == null || key.isEmpty) {
          return {
            "success": false,
            "error":
                "Element key, selector, or text is required. Use 'selector', 'key', or 'text' parameter."
          };
        }
        final image = await cdp.takeElementScreenshot(key);
        if (image == null)
          return {
            "success": false,
            "error": "Screenshot failed - element not found or not visible"
          };
        return {"success": true, "image": image};

      case 'scroll_to':
        return await cdp.scrollTo(key: args['key'], text: args['text']);

      case 'go_back':
        final success = await cdp.goBack();
        return success ? "Navigated back" : "Cannot go back";

      case 'get_current_route':
        return await cdp.getCurrentRoute();

      case 'get_navigation_stack':
        return await cdp.getNavigationStack();

      case 'swipe':
        final distance = (args['distance'] ?? 300).toDouble();
        final success = await cdp.swipe(
            direction: args['direction'], distance: distance, key: args['key']);
        return success ? "Swiped ${args['direction']}" : "Swipe failed";

      case 'long_press':
        final duration = args['duration'] ?? 500;
        final success = await cdp.longPress(
            key: args['key'], text: args['text'], duration: duration);
        return success ? "Long pressed" : "Long press failed";

      case 'double_tap':
        final success =
            await cdp.doubleTap(key: args['key'], text: args['text']);
        return success ? "Double tapped" : "Double tap failed";

      case 'wait_for_element':
        final timeout = args['timeout'] ?? 5000;
        final found = await cdp.waitForElement(
            key: args['key'], text: args['text'], timeout: timeout);
        return {"found": found};

      case 'wait_for_gone':
        final timeout = args['timeout'] ?? 5000;
        final gone = await cdp.waitForGone(
            key: args['key'], text: args['text'], timeout: timeout);
        return {"gone": gone};

      case 'assert_visible':
        final timeout = args['timeout'] ?? 5000;
        final found = await cdp.waitForElement(
            key: args['key'], text: args['text'], timeout: timeout);
        return {
          "success": found,
          "assertion": "visible",
          "element": args['key'] ?? args['text']
        };

      case 'assert_not_visible':
        final timeout = args['timeout'] ?? 5000;
        final gone = await cdp.waitForGone(
            key: args['key'], text: args['text'], timeout: timeout);
        return {
          "success": gone,
          "assertion": "not_visible",
          "element": args['key'] ?? args['text']
        };

      case 'get_text_content':
        return await cdp.getTextContent();

      case 'get_text_value':
        return await cdp.getTextValue(args['key']);

      case 'hot_reload':
        await cdp.hotReload();
        return "Page reloaded";

      case 'get_logs':
        return {
          "logs": [],
          "summary": {
            "total_count": 0,
            "message": "CDP log capture not available"
          }
        };

      case 'get_errors':
        return {
          "errors": [],
          "summary": {
            "total_count": 0,
            "message": "CDP error capture not available"
          }
        };

      case 'clear_logs':
        return {"success": true, "message": "No-op for CDP"};

      case 'drag':
        final startX = (args['startX'] as num?)?.toDouble() ?? 0;
        final startY = (args['startY'] as num?)?.toDouble() ?? 0;
        final endX = (args['endX'] as num?)?.toDouble() ?? 0;
        final endY = (args['endY'] as num?)?.toDouble() ?? 0;
        return await cdp.drag(startX, startY, endX, endY);

      case 'tap_at':
        final x = (args['x'] as num).toDouble();
        final y = (args['y'] as num).toDouble();
        await cdp.tapAt(x, y);
        return {
          "success": true,
          "position": {"x": x, "y": y}
        };

      case 'long_press_at':
        final x = (args['x'] as num).toDouble();
        final y = (args['y'] as num).toDouble();
        await cdp.longPressAt(x, y);
        return {
          "success": true,
          "position": {"x": x, "y": y}
        };

      case 'swipe_coordinates':
        final startX =
            (args['startX'] ?? args['start_x'] as num?)?.toDouble() ?? 0;
        final startY =
            (args['startY'] ?? args['start_y'] as num?)?.toDouble() ?? 0;
        final endX = (args['endX'] ?? args['end_x'] as num?)?.toDouble() ?? 0;
        final endY = (args['endY'] ?? args['end_y'] as num?)?.toDouble() ?? 0;
        return await cdp.swipeCoordinates(startX, startY, endX, endY);

      case 'edge_swipe':
        final direction = args['direction'] as String? ?? 'right';
        final edge = args['edge'] as String? ?? 'left';
        final distance = (args['distance'] as num?)?.toInt() ?? 200;
        return await cdp.edgeSwipe(direction, edge: edge, distance: distance);

      case 'gesture':
        final points = ((args['points'] ?? args['actions']) as List<dynamic>?)
                ?.cast<Map<String, dynamic>>() ??
            [];
        return await cdp.gesture(points);

      case 'scroll_until_visible':
        final key = args['key'] as String? ?? '';
        final maxScrolls = (args['max_scrolls'] as num?)?.toInt() ?? 10;
        final direction = args['direction'] as String? ?? 'down';
        return await cdp.scrollUntilVisible(key,
            maxScrolls: maxScrolls, direction: direction);

      case 'get_checkbox_state':
        final key = args['selector'] as String? ?? args['key'] as String? ?? '';
        if (key.isEmpty) {
          return {
            'success': false,
            'error':
                'selector or key is required. Provide a CSS selector, element ID, or element name.'
          };
        }
        return await cdp.getCheckboxState(key);

      case 'get_slider_value':
        final key = args['selector'] as String? ?? args['key'] as String? ?? '';
        if (key.isEmpty) {
          return {
            'success': false,
            'error':
                'selector or key is required. Provide a CSS selector, element ID, or element name.'
          };
        }
        return await cdp.getSliderValue(key);

      case 'get_page_state':
        return await cdp.getPageState();

      case 'get_interactable_elements':
        return await cdp.getInteractableElements();

      case 'get_performance':
        return await cdp.getPerformance();

      case 'get_frame_stats':
        return await cdp.getFrameStats();

      case 'get_memory_stats':
        return await cdp.getMemoryStats();

      case 'assert_text':
        final text = args['text'] as String? ?? '';
        final key = args['key'] as String?;
        return await cdp.assertText(text, key: key);

      case 'assert_element_count':
        final selector =
            args['selector'] as String? ?? args['key'] as String? ?? '*';
        final count = (args['expected_count'] as num?)?.toInt() ?? 0;
        return await cdp.assertElementCount(selector, count);

      case 'wait_for_idle':
        final timeoutMs = (args['timeout'] as num?)?.toInt() ?? 5000;
        return await cdp.waitForIdle(timeoutMs: timeoutMs);

      case 'diagnose':
        return await cdp.diagnose();

      case 'execute_batch':
        final actions = args['actions'] as List<dynamic>? ?? [];
        final results = <Map<String, dynamic>>[];
        for (final action in actions) {
          final a = action as Map<String, dynamic>;
          final actionName = (a['action'] ?? a['tool'] ?? a['name']) as String;
          final actionArgs = (a['args'] ?? a['arguments'] ?? a['params'])
                  as Map<String, dynamic>? ??
              {};
          try {
            final r = await _executeCdpTool(actionName, actionArgs, cdp);
            results.add({"action": actionName, "success": true, "result": r});
          } catch (e) {
            results.add({
              "action": actionName,
              "success": false,
              "error": e.toString()
            });
          }
        }
        return {"success": true, "results": results};

      case 'enable_test_indicators':
      case 'get_indicator_status':
        return {"success": true, "message": "No-op for CDP", "enabled": false};

      case 'enable_network_monitoring':
        return {
          "success": true,
          "message": "Network monitoring (no-op for CDP)"
        };

      case 'clear_network_requests':
        return {"success": true, "message": "No-op for CDP"};

      case 'eval':
        final expression = args['expression'] as String? ?? '';
        final result = await cdp.eval(expression);
        return result;

      case 'press_key':
        final key = args['key'] as String? ?? 'Enter';
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
        return {"success": true, "key": key};

      case 'type_text':
        final text = args['text'] as String? ?? '';
        await cdp.typeText(text);
        return {"success": true, "text": text};

      case 'paste_text':
        final text = args['text'] as String? ?? '';
        await cdp.pasteText(text);
        return {"success": true, "length": text.length};

      case 'fill_rich_text':
        return await cdp.fillRichText(
          selector: args['selector'] as String?,
          html: args['html'] as String?,
          text: args['text'] as String?,
          append: args['append'] == true,
        );

      case 'solve_captcha':
        final apiKey = args['api_key'] as String? ?? '';
        if (apiKey.isEmpty)
          return {"success": false, "message": "api_key is required"};
        return await cdp.solveCaptcha(
          apiKey: apiKey,
          siteKey: args['site_key'] as String?,
          pageUrl: args['page_url'] as String?,
          type: args['type'] as String?,
        );

      case 'hover':
        return await cdp.hover(
            key: args['key'], text: args['text'], ref: args['ref']);

      case 'select_option':
        final key = args['key'] as String? ?? '';
        final value = args['value'] as String? ?? '';
        return await cdp.selectOption(key, value);

      case 'set_checkbox':
        final key = args['key'] as String? ?? '';
        final checked = args['checked'] ?? true;
        return await cdp.setCheckbox(key, checked);

      case 'fill':
        final key = args['key'] as String? ?? '';
        final value = args['value'] ?? args['text'] as String? ?? '';
        return await cdp.fill(key, value);

      case 'get_cookies':
        return await cdp.getCookies();

      case 'set_cookie':
        return await cdp.setCookie(
          args['name'] as String? ?? '',
          args['value'] as String? ?? '',
          domain: args['domain'] as String?,
          path: args['path'] as String?,
        );

      case 'clear_cookies':
        return await cdp.clearCookies();

      case 'get_local_storage':
        return await cdp.getLocalStorage();

      case 'set_local_storage':
        return await cdp.setLocalStorage(
            args['key'] as String? ?? '', args['value'] as String? ?? '');

      case 'clear_local_storage':
        return await cdp.clearLocalStorage();

      case 'get_console_messages':
        return await cdp.getConsoleMessages();

      case 'get_network_requests':
        return await cdp.getNetworkRequests(
            limit: (args['limit'] as num?)?.toInt() ?? 100);

      case 'set_viewport':
        return await cdp.setViewport(
          (args['width'] as num?)?.toInt() ?? 1280,
          (args['height'] as num?)?.toInt() ?? 720,
          deviceScaleFactor:
              (args['device_scale_factor'] as num?)?.toDouble() ?? 1.0,
        );

      case 'emulate_device':
        return await cdp.emulateDevice(args['device'] as String? ?? '');

      case 'generate_pdf':
        return await cdp.generatePdf();

      case 'navigate':
        return await cdp.navigate(args['url'] as String? ?? '');

      case 'go_forward':
        await cdp.goForward();
        return {"success": true};

      case 'reload':
        return await cdp.reload();

      case 'get_attribute':
        return await cdp.getAttribute(
            args['key'] as String? ?? '', args['attribute'] as String? ?? '');

      case 'get_css_property':
        return await cdp.getCssProperty(
            args['key'] as String? ?? '', args['property'] as String? ?? '');

      case 'get_bounding_box':
        return await cdp.getBoundingBox(args['key'] as String? ?? '');

      case 'focus':
        return await cdp.focus(args['key'] as String? ?? '');

      case 'blur':
        return await cdp.blur(args['key'] as String? ?? '');

      case 'get_title':
        return {"title": await cdp.getTitle()};

      case 'set_geolocation':
        return await cdp.setGeolocation(
          (args['latitude'] as num?)?.toDouble() ?? 0,
          (args['longitude'] as num?)?.toDouble() ?? 0,
        );

      case 'set_timezone':
        return await cdp.setTimezone(args['timezone'] as String? ?? 'UTC');

      case 'set_color_scheme':
        return await cdp.setColorScheme(args['scheme'] as String? ?? 'dark');

      case 'block_urls':
        return await cdp.blockUrls(
            (args['patterns'] as List<dynamic>?)?.cast<String>() ?? []);

      case 'throttle_network':
        return await cdp.throttleNetwork(
          latencyMs: (args['latency_ms'] as num?)?.toInt() ?? 0,
          downloadKbps: (args['download_kbps'] as num?)?.toInt() ?? -1,
          uploadKbps: (args['upload_kbps'] as num?)?.toInt() ?? -1,
        );

      case 'go_offline':
        return await cdp.goOffline();

      case 'go_online':
        return await cdp.goOnline();

      case 'clear_browser_data':
        return await cdp.clearBrowserData();

      case 'upload_file':
        final selector = args['selector'] as String? ?? 'input[type="file"]';
        final files = (args['files'] as List<dynamic>?)?.cast<String>() ?? [];
        return await cdp.uploadFile(selector, files);

      case 'handle_dialog':
        final accept = args['accept'] ?? true;
        final promptText = args['prompt_text'] as String?;
        return await cdp.handleDialog(accept, promptText: promptText);

      case 'get_frames':
        return await cdp.getFrames();

      case 'eval_in_frame':
        return await cdp.evalInFrame(args['frame_id'] as String? ?? '',
            args['expression'] as String? ?? '');

      case 'get_tabs':
        return await cdp.getTabs();

      case 'new_tab':
        return await cdp.newTab(args['url'] as String? ?? 'about:blank');

      case 'close_tab':
        var closeTargetId = args['target_id'] as String? ?? '';
        if (closeTargetId.isEmpty && args['index'] != null) {
          final idx = (args['index'] as num).toInt();
          final tabList = await cdp.getTabs();
          final tabItems = tabList['tabs'] as List<dynamic>? ?? [];
          if (idx >= 0 && idx < tabItems.length) {
            closeTargetId =
                (tabItems[idx] as Map<String, dynamic>)['id'] as String? ?? '';
          }
        }
        if (closeTargetId.isEmpty)
          return {"success": false, "error": "No target_id or valid index"};
        return await cdp.closeTab(closeTargetId);

      case 'switch_tab':
        var switchTargetId = args['target_id'] as String? ?? '';
        if (switchTargetId.isEmpty && args['index'] != null) {
          final idx = (args['index'] as num).toInt();
          final tabList = await cdp.getTabs();
          final tabItems = tabList['tabs'] as List<dynamic>? ?? [];
          if (idx >= 0 && idx < tabItems.length) {
            switchTargetId =
                (tabItems[idx] as Map<String, dynamic>)['id'] as String? ?? '';
          }
        }
        if (switchTargetId.isEmpty)
          return {"success": false, "error": "No target_id or valid index"};
        return await cdp.switchTab(switchTargetId);

      case 'intercept_requests':
        return await cdp.interceptRequests(
          args['url_pattern'] as String? ?? '*',
          statusCode: (args['status_code'] as num?)?.toInt(),
          body: args['body'] as String?,
          headers: (args['headers'] as Map<String, dynamic>?)
              ?.cast<String, String>(),
        );

      case 'clear_interceptions':
        return await cdp.clearInterceptions();

      case 'accessibility_audit':
        return await cdp.accessibilityAudit();

      case 'compare_screenshot':
        return await cdp
            .compareScreenshot(args['baseline_path'] as String? ?? '');

      case 'wait_for_network_idle':
        return await cdp.waitForNetworkIdle(
          timeoutMs: (args['timeout_ms'] as num?)?.toInt() ?? 10000,
          idleMs: (args['idle_ms'] as num?)?.toInt() ?? 500,
        );

      case 'get_session_storage':
        return await cdp.getSessionStorage();

      case 'count_elements':
        final selector = args['selector'] as String? ?? '*';
        return {
          "count": await cdp.countElements(selector),
          "selector": selector
        };

      case 'is_visible':
        final key = args['key'] as String? ?? '';
        return {"visible": await cdp.isVisible(key), "key": key};

      case 'get_page_source':
        return {
          "source": await cdp.getPageSource(
            selector: args['selector'] as String?,
            removeScripts: args['remove_scripts'] == true,
            removeStyles: args['remove_styles'] == true,
            removeComments: args['remove_comments'] == true,
            removeMeta: args['remove_meta'] == true,
            minify: args['minify'] == true,
            cleanHtml: args['clean_html'] == true,
          )
        };

      case 'get_visible_text':
        return {
          "text":
              await cdp.getVisibleText(selector: args['selector'] as String?)
        };

      case 'get_window_handles':
        return await cdp.getWindowHandles();

      case 'install_dialog_handler':
        final autoAccept = args['auto_accept'] ?? true;
        await cdp.installDialogHandler(autoAccept: autoAccept);
        return {"success": true, "auto_accept": autoAccept};

      case 'wait_for_navigation':
        return await cdp.waitForNavigation(
          timeoutMs: (args['timeout_ms'] as num?)?.toInt() ?? 30000,
        );

      case 'highlight_element':
        final selector = args['selector'] as String? ??
            args['key'] as String? ??
            args['ref'] as String? ??
            '';
        final color = args['color'] as String? ?? 'red';
        final duration = (args['duration_ms'] as num?)?.toInt() ?? 3000;
        if (selector.isEmpty) {
          return {
            'success': false,
            'error':
                'selector, key, or ref is required. Provide a CSS selector, element ID, or ref name.'
          };
        }
        return await cdp.highlightElement(selector,
            color: color, duration: duration);

      case 'mock_response':
        final urlPattern = args['url_pattern'] as String? ?? '*';
        final statusCode = (args['status_code'] as num?)?.toInt() ?? 200;
        final body = args['body'] as String? ?? '';
        final headers =
            (args['headers'] as Map<String, dynamic>?)?.cast<String, String>();
        return await cdp.mockResponse(urlPattern, statusCode, body,
            headers: headers);

      case 'highlight_elements':
        final show = args['show'] ?? true;
        if (show) {
          final js = '''
(function() {
  if (window.__fsHighlightStyle) return JSON.stringify({success: true, message: 'Already active'});
  var style = document.createElement('style');
  style.id = '__fs_highlight_style';
  style.textContent = 'a,button,input,select,textarea,[role="button"],[role="link"],[role="tab"],[onclick],[tabindex] { outline: 2px solid rgba(255,0,128,0.7) !important; outline-offset: 2px !important; } a:hover,button:hover,input:hover,select:hover,textarea:hover,[role="button"]:hover { outline-color: rgba(0,128,255,0.9) !important; }';
  document.head.appendChild(style);
  window.__fsHighlightStyle = style;
  var count = document.querySelectorAll('a,button,input,select,textarea,[role="button"],[role="link"],[role="tab"],[onclick],[tabindex]').length;
  return JSON.stringify({success: true, highlighted: count});
})()
''';
          final result = await cdp.eval(js);
          final v = result['result']?['value'] as String?;
          if (v != null) return jsonDecode(v);
          return {'success': true};
        } else {
          await cdp.eval(
              "if(window.__fsHighlightStyle){window.__fsHighlightStyle.remove();delete window.__fsHighlightStyle;}");
          return {'success': true, 'message': 'Highlights removed'};
        }

      case 'discover_page_tools':
        return await cdp.discoverTools();

      case 'call_page_tool':
        final toolName = args['name'] as String? ?? '';
        final toolParams = (args['params'] as Map<String, dynamic>?) ?? {};
        return await cdp.callTool(toolName, toolParams);

      case 'auto_discover_forms':
        return await cdp.autoDiscoverForms();

      default:
        throw Exception('Tool "$name" is not supported in CDP mode.');
    }
  }
}
