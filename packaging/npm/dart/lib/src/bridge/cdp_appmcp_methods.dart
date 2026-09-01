part of 'cdp_driver.dart';

/// AppMCP methods: tool discovery, tool calling, form discovery,
/// element highlighting, response mocking.
extension CdpAppmcpMethods on CdpDriver {
  /// Highlight an element with a colored overlay.
  Future<Map<String, dynamic>> highlightElement(String selector,
      {String? color, int duration = 3000}) async {
    final c = color ?? 'red';
    final js = '''
(function() {
  var el = document.querySelector('$selector') || document.getElementById('$selector') || document.querySelector('[data-testid="$selector"]');
  if (!el) return JSON.stringify({success: false, error: 'Element not found'});
  var rect = el.getBoundingClientRect();
  var overlay = document.createElement('div');
  overlay.id = '__fs_highlight_' + Date.now();
  overlay.style.cssText = 'position:fixed;top:'+rect.top+'px;left:'+rect.left+'px;width:'+rect.width+'px;height:'+rect.height+'px;border:3px solid $c;background:${c}33;z-index:2147483647;pointer-events:none;transition:opacity 0.3s;';
  document.body.appendChild(overlay);
  setTimeout(function(){ overlay.style.opacity='0'; setTimeout(function(){ overlay.remove(); }, 300); }, $duration);
  return JSON.stringify({success: true, selector: '$selector', color: '$c', duration: $duration, bounds: {x: rect.x, y: rect.y, w: rect.width, h: rect.height}});
})()
''';
    final result = await _evalJs(js);
    final v = result['result']?['value'] as String?;
    if (v != null) return jsonDecode(v) as Map<String, dynamic>;
    return {'success': false, 'error': 'Eval failed'};
  }

  /// Mock a network response for requests matching a URL pattern.
  Future<Map<String, dynamic>> mockResponse(
      String urlPattern, int statusCode, String body,
      {Map<String, String>? headers}) async {
    return await interceptRequests(urlPattern,
        statusCode: statusCode, body: body, headers: headers);
  }

  // ── WebMCP: Discover and call structured page tools ──

  /// Discover all tools on the current page from multiple sources:
  /// 0. Chrome 146+ native WebMCP (navigator.modelContextTesting)
  /// 1. JS-registered tools (window.__flutter_skill_tools__)
  /// 2. data-mcp-tool annotated forms
  /// 3. <link rel="mcp-tools"> manifest
  /// 4. /.well-known/mcp.json
  /// 5. Auto-converted <form> elements
  Future<Map<String, dynamic>> discoverTools() async {
    final result = await _call('Runtime.evaluate', {
      'expression': '''
      (async () => {
        const tools = [];
        // 0. Chrome 146+ native WebMCP API (navigator.modelContextTesting)
        if (typeof navigator !== 'undefined' && navigator.modelContextTesting) {
          try {
            const webMcpTools = await navigator.modelContextTesting.getTools();
            webMcpTools.forEach(t => {
              tools.push({
                name: t.name,
                description: t.description || '',
                params: t.inputSchema && t.inputSchema.properties ? t.inputSchema.properties : {},
                inputSchema: t.inputSchema || null,
                annotations: t.annotations || {},
                source: 'webmcp-native',
              });
            });
          } catch(e) {}
        }
        // 1. JS-registered tools
        if (window.__flutter_skill_tools__ && Array.isArray(window.__flutter_skill_tools__)) {
          window.__flutter_skill_tools__.forEach(t => {
            tools.push({ name: t.name, description: t.description || '', params: t.params || {}, source: 'js-registered', hasHandler: typeof t.handler === 'function' });
          });
        }
        // 2. data-mcp-tool annotated elements
        document.querySelectorAll('[data-mcp-tool]').forEach(el => {
          const name = el.getAttribute('data-mcp-tool');
          const desc = el.getAttribute('data-mcp-description') || '';
          const params = {};
          el.querySelectorAll('[data-mcp-param]').forEach(input => {
            const pName = input.getAttribute('data-mcp-param');
            params[pName] = { type: input.getAttribute('data-mcp-type') || 'string', required: input.hasAttribute('data-mcp-required'), description: input.getAttribute('data-mcp-description') || input.getAttribute('placeholder') || '' };
          });
          el.querySelectorAll('input[name], textarea[name], select[name]').forEach(input => {
            if (!input.hasAttribute('data-mcp-param')) {
              const pName = input.getAttribute('name');
              if (!params[pName]) params[pName] = { type: input.type === 'number' ? 'number' : input.type === 'checkbox' ? 'boolean' : 'string', required: input.required, description: input.getAttribute('placeholder') || '' };
            }
          });
          tools.push({ name: name, description: desc, params: params, source: 'data-mcp-tool' });
        });
        // 3. <link rel="mcp-tools"> manifests
        for (const link of document.querySelectorAll('link[rel="mcp-tools"]')) {
          try { const r = await fetch(link.href); const m = await r.json(); if (m.tools) m.tools.forEach(t => tools.push({ ...t, source: 'link-manifest', manifestUrl: link.href })); } catch(e) {}
        }
        // 4. /.well-known/mcp.json
        try { const r = await fetch('/.well-known/mcp.json'); if (r.ok) { const m = await r.json(); if (m.tools) m.tools.forEach(t => tools.push({ ...t, source: 'well-known' })); } } catch(e) {}
        // 5. Auto-discover forms
        document.querySelectorAll('form').forEach((form, i) => {
          if (form.hasAttribute('data-mcp-tool')) return;
          const fid = form.id || form.getAttribute('name') || '';
          const name = 'form_' + (fid || i);
          const params = {};
          form.querySelectorAll('input[name], textarea[name], select[name]').forEach(input => {
            const pName = input.getAttribute('name');
            const label = (input.labels && input.labels[0]) ? input.labels[0].textContent.trim() : '';
            params[pName] = { type: input.type === 'number' ? 'number' : input.type === 'checkbox' ? 'boolean' : 'string', required: input.required, description: label || input.getAttribute('placeholder') || '' };
          });
          if (Object.keys(params).length > 0) tools.push({ name: name, description: 'Form: ' + (fid || form.getAttribute('action') || 'unnamed'), params: params, source: 'auto-form', formAction: form.getAttribute('action') || '', formMethod: (form.getAttribute('method') || 'GET').toUpperCase() });
        });
        // 6. Auto-discover ALL interactive elements as tools (zero-config)
        const seen = new Set(tools.map(t => t.name));
        document.querySelectorAll('button, a[href], input, textarea, select, [role="button"], [role="link"], [role="switch"], [role="slider"], [onclick]').forEach((el, i) => {
          const tag = el.tagName.toLowerCase();
          const text = (el.textContent || '').trim().substring(0, 50);
          const id = el.id || el.getAttribute('name') || '';
          const label = text || id || el.getAttribute('aria-label') || '';
          if (!label) return;
          const safeName = label.toLowerCase().replace(/[^a-z0-9]/g, '_').replace(/_+/g, '_').replace(/^_|_\$/g, '');
          if (!safeName) return;
          const role = el.getAttribute('role') || '';
          let toolName, desc, action, params = {};
          if (tag === 'input' || tag === 'textarea') {
            toolName = 'fill_' + safeName;
            desc = 'Enter text: ' + label;
            action = 'enter_text';
            params = { text: { type: 'string', required: true } };
          } else if (tag === 'select') {
            toolName = 'select_' + safeName;
            desc = 'Select: ' + label;
            action = 'select';
            params = { value: { type: 'string', required: true } };
          } else if (role === 'switch' || el.type === 'checkbox') {
            toolName = 'toggle_' + safeName;
            desc = 'Toggle: ' + label;
            action = 'tap';
          } else if (role === 'slider' || el.type === 'range') {
            toolName = 'set_' + safeName;
            desc = 'Set slider: ' + label;
            action = 'set_value';
            params = { value: { type: 'number', required: true } };
          } else {
            toolName = 'tap_' + safeName;
            desc = 'Tap: ' + label;
            action = 'tap';
          }
          if (!seen.has(toolName)) {
            seen.add(toolName);
            const selector = id ? '#' + CSS.escape(id) : null;
            tools.push({ name: toolName, description: desc, params, source: 'auto-ui', action, selector, elementIndex: i });
          }
        });
        return JSON.stringify({ tools: tools, count: tools.length });
      })()
      ''',
      'returnByValue': true,
      'awaitPromise': true,
    });
    final v = result['result']?['value'] as String?;
    if (v != null) return jsonDecode(v) as Map<String, dynamic>;
    return {'tools': [], 'count': 0};
  }

  /// Call a discovered tool by name with parameters.
  /// Routes to the appropriate handler based on tool source.
  Future<Map<String, dynamic>> callTool(
      String toolName, Map<String, dynamic> params) async {
    final paramsJson = jsonEncode(params);
    final escapedName = jsonEncode(toolName);
    final result = await _call('Runtime.evaluate', {
      'expression': '''
      (async () => {
        const toolName = $escapedName;
        const params = $paramsJson;
        // 0. Chrome 146+ native WebMCP API (navigator.modelContextTesting)
        if (typeof navigator !== 'undefined' && navigator.modelContextTesting) {
          try {
            const allTools = await navigator.modelContextTesting.getTools();
            const found = allTools.find(t => t.name === toolName);
            if (found) {
              const result = await navigator.modelContextTesting.executeTool(toolName, params);
              return JSON.stringify({ success: true, result: result, source: 'webmcp-native' });
            }
          } catch(e) {}
        }
        // 1. JS-registered tools
        if (window.__flutter_skill_tools__) {
          const tool = window.__flutter_skill_tools__.find(t => t.name === toolName);
          if (tool && typeof tool.handler === 'function') {
            try {
              const result = await tool.handler(params);
              return JSON.stringify({ success: true, result: result, source: 'js-registered' });
            } catch (e) {
              return JSON.stringify({ success: false, error: e.message, source: 'js-registered' });
            }
          }
        }
        // 2. data-mcp-tool forms
        const mcpForm = document.querySelector('[data-mcp-tool="' + toolName + '"]');
        if (mcpForm) {
          for (const [key, value] of Object.entries(params)) {
            const input = mcpForm.querySelector('[name="' + key + '"], [data-mcp-param="' + key + '"]');
            if (input) {
              if (input.type === 'checkbox') input.checked = !!value;
              else input.value = value;
              input.dispatchEvent(new Event('input', { bubbles: true }));
              input.dispatchEvent(new Event('change', { bubbles: true }));
            }
          }
          if (typeof mcpForm.requestSubmit === 'function') mcpForm.requestSubmit();
          else mcpForm.submit();
          return JSON.stringify({ success: true, source: 'data-mcp-tool', action: 'form-submitted' });
        }
        // 3. Auto-discovered forms
        const forms = document.querySelectorAll('form');
        for (let i = 0; i < forms.length; i++) {
          const form = forms[i];
          const fid = form.id || form.getAttribute('name') || '';
          const formName = 'form_' + (fid || i);
          if (formName === toolName) {
            for (const [key, value] of Object.entries(params)) {
              const input = form.querySelector('[name="' + key + '"]');
              if (input) {
                if (input.type === 'checkbox') input.checked = !!value;
                else input.value = value;
                input.dispatchEvent(new Event('input', { bubbles: true }));
                input.dispatchEvent(new Event('change', { bubbles: true }));
              }
            }
            if (typeof form.requestSubmit === 'function') form.requestSubmit();
            else form.submit();
            return JSON.stringify({ success: true, source: 'auto-form', action: 'form-submitted' });
          }
        }
        // 4. Auto-UI tools (tap/fill/toggle by selector or text)
        if (toolName.startsWith('tap_') || toolName.startsWith('toggle_')) {
          const els = document.querySelectorAll('button, a[href], [role="button"], [role="link"], [role="switch"], [onclick], input[type="checkbox"]');
          for (const el of els) {
            const text = (el.textContent || '').trim().substring(0, 50);
            const id = el.id || el.getAttribute('name') || '';
            const label = text || id || el.getAttribute('aria-label') || '';
            const safeName = label.toLowerCase().replace(/[^a-z0-9]/g, '_').replace(/_+/g, '_').replace(/^_|_\$/g, '');
            const prefix = (el.getAttribute('role') === 'switch' || el.type === 'checkbox') ? 'toggle_' : 'tap_';
            if (prefix + safeName === toolName) {
              el.click();
              return JSON.stringify({ success: true, source: 'auto-ui', action: 'clicked', element: label });
            }
          }
        }
        if (toolName.startsWith('fill_')) {
          const els = document.querySelectorAll('input, textarea');
          for (const el of els) {
            const text = (el.textContent || '').trim().substring(0, 50);
            const id = el.id || el.getAttribute('name') || '';
            const label = text || id || el.getAttribute('aria-label') || el.getAttribute('placeholder') || '';
            const safeName = label.toLowerCase().replace(/[^a-z0-9]/g, '_').replace(/_+/g, '_').replace(/^_|_\$/g, '');
            if ('fill_' + safeName === toolName) {
              el.focus();
              el.value = params.text || '';
              el.dispatchEvent(new Event('input', { bubbles: true }));
              el.dispatchEvent(new Event('change', { bubbles: true }));
              return JSON.stringify({ success: true, source: 'auto-ui', action: 'filled', element: label });
            }
          }
        }
        return JSON.stringify({ success: false, error: 'Tool not found: ' + toolName });
      })()
      ''',
      'returnByValue': true,
      'awaitPromise': true,
    });
    final v = result['result']?['value'] as String?;
    if (v != null) return jsonDecode(v) as Map<String, dynamic>;
    return {'success': false, 'error': 'Evaluation failed'};
  }

  /// Auto-discover ALL form elements on the page and convert them to tools.
  Future<Map<String, dynamic>> autoDiscoverForms() async {
    final result = await _evalJs('''
      (() => {
        const tools = [];
        document.querySelectorAll('form').forEach((form, i) => {
          const fid = form.id || form.getAttribute('name') || '';
          const action = form.getAttribute('action') || '';
          const method = (form.getAttribute('method') || 'GET').toUpperCase();
          const name = 'form_' + (fid || i);
          const params = {};
          form.querySelectorAll('input, textarea, select').forEach(input => {
            const inputName = input.getAttribute('name') || input.id || '';
            if (!inputName || input.type === 'hidden' || input.type === 'submit') return;
            const label = (input.labels && input.labels[0]) ? input.labels[0].textContent.trim() : '';
            const placeholder = input.getAttribute('placeholder') || '';
            const ariaLabel = input.getAttribute('aria-label') || '';
            params[inputName] = {
              type: input.type === 'number' || input.type === 'range' ? 'number'
                  : input.type === 'checkbox' ? 'boolean'
                  : input.type === 'email' ? 'string (email)'
                  : input.type === 'date' ? 'string (date)'
                  : 'string',
              required: input.required || input.hasAttribute('data-mcp-required'),
              description: label || ariaLabel || placeholder || inputName,
              inputType: input.type || 'text',
              tag: input.tagName.toLowerCase()
            };
          });
          tools.push({
            name: name,
            description: fid ? ('Form: ' + fid) : ('Form #' + i + (action ? ' → ' + action : '')),
            params: params,
            fieldCount: Object.keys(params).length,
            source: 'auto-form',
            formAction: action,
            formMethod: method,
            hasSubmitButton: !!form.querySelector('[type="submit"], button:not([type="button"])')
          });
        });
        return JSON.stringify({ tools: tools, count: tools.length });
      })()
    ''');
    final v = result['result']?['value'] as String?;
    if (v != null) return jsonDecode(v) as Map<String, dynamic>;
    return {'tools': [], 'count': 0};
  }
}
