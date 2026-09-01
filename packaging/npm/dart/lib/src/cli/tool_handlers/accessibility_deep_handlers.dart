part of '../server.dart';

extension _AccessibilityDeepHandlers on FlutterMcpServer {
  /// Deep accessibility audit tools.
  /// Returns null if the tool is not handled by this group.
  Future<dynamic> _handleAccessibilityDeepTools(
      String name, Map<String, dynamic> args) async {
    switch (name) {
      case 'a11y_full_audit':
        return _handleA11yFullAudit(args);
      case 'a11y_tab_order':
        return _handleA11yTabOrder(args);
      case 'a11y_color_contrast':
        return _handleA11yColorContrast(args);
      case 'a11y_screen_reader':
        return _handleA11yScreenReader(args);
      default:
        return null;
    }
  }

  CdpDriver _requireCdpForA11y() {
    final cdp = _cdpDriver;
    if (cdp == null) {
      throw Exception(
          'Deep accessibility audit requires an active CDP connection');
    }
    return cdp;
  }

  Future<Map<String, dynamic>> _handleA11yFullAudit(
      Map<String, dynamic> args) async {
    final cdp = _requireCdpForA11y();
    final level = args['level'] as String? ?? 'AA';
    final includeWarnings = args['include_warnings'] ?? true;

    final js = '''
(function() {
  var issues = [];
  var warnings = [];
  var passed = [];

  // 1. Images without alt text
  document.querySelectorAll('img').forEach(function(img) {
    if (!img.hasAttribute('alt')) {
      issues.push({rule: 'img-alt', level: 'A', element: img.outerHTML.substring(0, 200), message: 'Image missing alt attribute'});
    } else if (img.alt.trim() === '') {
      // Decorative images with empty alt are OK if they have role="presentation"
      if (img.getAttribute('role') !== 'presentation' && img.getAttribute('role') !== 'none') {
        warnings.push({rule: 'img-alt-empty', level: 'A', element: img.outerHTML.substring(0, 200), message: 'Image has empty alt but no role="presentation"'});
      }
    }
  });

  // 2. Form labels
  document.querySelectorAll('input, select, textarea').forEach(function(el) {
    if (el.type === 'hidden' || el.type === 'submit' || el.type === 'button' || el.type === 'reset') return;
    var id = el.id;
    var hasLabel = false;
    if (id && document.querySelector('label[for="' + id + '"]')) hasLabel = true;
    if (el.closest('label')) hasLabel = true;
    if (el.getAttribute('aria-label') || el.getAttribute('aria-labelledby')) hasLabel = true;
    if (el.getAttribute('title')) hasLabel = true;
    if (!hasLabel) {
      issues.push({rule: 'form-label', level: 'A', element: el.outerHTML.substring(0, 200), message: 'Form control missing associated label'});
    }
  });

  // 3. Heading hierarchy
  var headings = document.querySelectorAll('h1, h2, h3, h4, h5, h6');
  var lastLevel = 0;
  headings.forEach(function(h) {
    var currentLevel = parseInt(h.tagName.charAt(1));
    if (lastLevel > 0 && currentLevel > lastLevel + 1) {
      issues.push({rule: 'heading-order', level: 'A', element: h.outerHTML.substring(0, 200), message: 'Heading level skipped: h' + lastLevel + ' to h' + currentLevel});
    }
    lastLevel = currentLevel;
  });

  // 4. ARIA role validity
  var validRoles = ['alert','alertdialog','application','article','banner','button','cell','checkbox','columnheader','combobox','complementary','contentinfo','definition','dialog','directory','document','feed','figure','form','grid','gridcell','group','heading','img','link','list','listbox','listitem','log','main','marquee','math','menu','menubar','menuitem','menuitemcheckbox','menuitemradio','navigation','none','note','option','presentation','progressbar','radio','radiogroup','region','row','rowgroup','rowheader','scrollbar','search','searchbox','separator','slider','spinbutton','status','switch','tab','table','tablist','tabpanel','term','textbox','timer','toolbar','tooltip','tree','treegrid','treeitem'];
  document.querySelectorAll('[role]').forEach(function(el) {
    var role = el.getAttribute('role');
    if (role && validRoles.indexOf(role) === -1) {
      issues.push({rule: 'aria-role', level: 'A', element: el.outerHTML.substring(0, 200), message: 'Invalid ARIA role: ' + role});
    }
  });

  // 5. Link text quality
  document.querySelectorAll('a').forEach(function(a) {
    var text = (a.textContent || '').trim().toLowerCase();
    if (!text && !a.querySelector('img[alt]') && !a.getAttribute('aria-label')) {
      issues.push({rule: 'link-text', level: 'A', element: a.outerHTML.substring(0, 200), message: 'Link has no text content'});
    } else if (['click here', 'here', 'read more', 'more', 'link'].indexOf(text) !== -1) {
      warnings.push({rule: 'link-text-quality', level: 'AA', element: a.outerHTML.substring(0, 200), message: 'Non-descriptive link text: "' + text + '"'});
    }
  });

  // 6. Touch target size (44x44 minimum)
  document.querySelectorAll('a, button, input, select, textarea, [role="button"], [role="link"], [onclick]').forEach(function(el) {
    var rect = el.getBoundingClientRect();
    if (rect.width > 0 && rect.height > 0) {
      if (rect.width < 44 || rect.height < 44) {
        warnings.push({rule: 'touch-target', level: 'AAA', element: el.outerHTML.substring(0, 200), message: 'Touch target too small: ' + Math.round(rect.width) + 'x' + Math.round(rect.height) + 'px (min 44x44)'});
      }
    }
  });

  // 7. Color contrast (sample text elements)
  function luminance(r, g, b) {
    var a = [r, g, b].map(function(v) {
      v /= 255;
      return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
    });
    return 0.2126 * a[0] + 0.7152 * a[1] + 0.0722 * a[2];
  }
  function parseColor(c) {
    var m = c.match(/rgba?\\((\\d+),\\s*(\\d+),\\s*(\\d+)/);
    return m ? [parseInt(m[1]), parseInt(m[2]), parseInt(m[3])] : null;
  }
  function contrastRatio(l1, l2) {
    var lighter = Math.max(l1, l2);
    var darker = Math.min(l1, l2);
    return (lighter + 0.05) / (darker + 0.05);
  }
  var textEls = document.querySelectorAll('p, span, a, button, label, li, td, th, h1, h2, h3, h4, h5, h6, div');
  var contrastIssues = 0;
  textEls.forEach(function(el) {
    if (contrastIssues > 20) return; // Limit checks
    var style = window.getComputedStyle(el);
    var text = (el.textContent || '').trim();
    if (!text) return;
    var fg = parseColor(style.color);
    var bg = parseColor(style.backgroundColor);
    if (fg && bg) {
      var fgL = luminance(fg[0], fg[1], fg[2]);
      var bgL = luminance(bg[0], bg[1], bg[2]);
      var ratio = contrastRatio(fgL, bgL);
      var fontSize = parseFloat(style.fontSize);
      var isLarge = fontSize >= 18 || (fontSize >= 14 && style.fontWeight >= 700);
      var minRatio = isLarge ? 3.0 : 4.5;
      ''' +
        (level == 'AAA' ? "minRatio = isLarge ? 4.5 : 7.0;" : "") +
        '''
      if (ratio < minRatio) {
        contrastIssues++;
        issues.push({rule: 'color-contrast', level: '${level}', element: el.outerHTML.substring(0, 200), message: 'Insufficient contrast: ' + ratio.toFixed(2) + ':1 (needs ' + minRatio + ':1)', ratio: ratio, required: minRatio});
      }
    }
  });

  // 8. Focus visibility check
  document.querySelectorAll('a, button, input, select, textarea, [tabindex]').forEach(function(el) {
    var style = window.getComputedStyle(el);
    if (style.outlineStyle === 'none' && style.outlineWidth === '0px') {
      // Check if there's a :focus style (heuristic)
      warnings.push({rule: 'focus-visible', level: 'AA', element: el.tagName + (el.id ? '#'+el.id : '') + (el.className ? '.'+String(el.className).split(' ')[0] : ''), message: 'Element may lack visible focus indicator'});
    }
  });

  // 9. Document language
  if (!document.documentElement.hasAttribute('lang')) {
    issues.push({rule: 'html-lang', level: 'A', element: '<html>', message: 'Document missing lang attribute'});
  }

  // Filter by level
  var levelOrder = {'A': 1, 'AA': 2, 'AAA': 3};
  var targetLevel = levelOrder['${level}'] || 2;
  issues = issues.filter(function(i) { return (levelOrder[i.level] || 1) <= targetLevel; });
  if (!${includeWarnings}) warnings = [];

  passed.push('Total elements checked');
  return JSON.stringify({
    success: true,
    level: '${level}',
    issues: issues,
    warnings: warnings,
    summary: {
      total_issues: issues.length,
      total_warnings: warnings.length,
      critical: issues.filter(function(i) { return i.level === 'A'; }).length,
      serious: issues.filter(function(i) { return i.level === 'AA'; }).length,
      moderate: issues.filter(function(i) { return i.level === 'AAA'; }).length,
    }
  });
})()
''';
    final result = await cdp.eval(js);
    final value = result['result']?['value'] as String?;
    if (value != null) {
      return jsonDecode(value) as Map<String, dynamic>;
    }
    return {
      'success': false,
      'error': 'Failed to execute audit',
      'raw': result
    };
  }

  Future<Map<String, dynamic>> _handleA11yTabOrder(
      Map<String, dynamic> args) async {
    final cdp = _requireCdpForA11y();
    final maxTabs = (args['max_tabs'] as num?)?.toInt() ?? 50;

    final js = '''
(function() {
  var elements = [];
  var activeElement = document.activeElement;

  // Focus the body first to start from beginning
  document.body.focus();

  for (var i = 0; i < $maxTabs; i++) {
    // Simulate Tab key
    var event = new KeyboardEvent('keydown', {key: 'Tab', code: 'Tab', keyCode: 9, which: 9, bubbles: true});
    document.dispatchEvent(event);

    // Move focus manually since synthetic events don't move focus
    var focusable = Array.from(document.querySelectorAll(
      'a[href], button:not([disabled]), input:not([disabled]):not([type="hidden"]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])'
    )).filter(function(el) {
      var style = window.getComputedStyle(el);
      return style.display !== 'none' && style.visibility !== 'hidden' && el.offsetParent !== null;
    });

    // Sort by tabindex then DOM order
    focusable.sort(function(a, b) {
      var ta = parseInt(a.getAttribute('tabindex') || '0');
      var tb = parseInt(b.getAttribute('tabindex') || '0');
      if (ta === 0 && tb === 0) return 0;
      if (ta === 0) return 1;
      if (tb === 0) return -1;
      return ta - tb;
    });

    if (i >= focusable.length) break;

    var el = focusable[i];
    elements.push({
      index: i + 1,
      tag: el.tagName.toLowerCase(),
      type: el.type || null,
      id: el.id || null,
      name: el.name || null,
      text: (el.textContent || '').trim().substring(0, 100),
      tabindex: el.getAttribute('tabindex'),
      role: el.getAttribute('role'),
      ariaLabel: el.getAttribute('aria-label'),
      rect: {
        x: Math.round(el.getBoundingClientRect().x),
        y: Math.round(el.getBoundingClientRect().y),
        width: Math.round(el.getBoundingClientRect().width),
        height: Math.round(el.getBoundingClientRect().height),
      }
    });
  }

  // Restore original focus
  if (activeElement) activeElement.focus();

  return JSON.stringify({
    success: true,
    tab_order: elements,
    total_focusable: elements.length,
  });
})()
''';
    final result = await cdp.eval(js);
    final value = result['result']?['value'] as String?;
    if (value != null) {
      return jsonDecode(value) as Map<String, dynamic>;
    }
    return {
      'success': false,
      'error': 'Failed to get tab order',
      'raw': result
    };
  }

  Future<Map<String, dynamic>> _handleA11yColorContrast(
      Map<String, dynamic> args) async {
    final cdp = _requireCdpForA11y();
    final level = args['level'] as String? ?? 'AA';

    final js = '''
(function() {
  function srgbToLinear(v) {
    v /= 255;
    return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
  }
  function luminance(r, g, b) {
    return 0.2126 * srgbToLinear(r) + 0.7152 * srgbToLinear(g) + 0.0722 * srgbToLinear(b);
  }
  function parseColor(c) {
    var m = c.match(/rgba?\\((\\d+),\\s*(\\d+),\\s*(\\d+)/);
    return m ? [parseInt(m[1]), parseInt(m[2]), parseInt(m[3])] : null;
  }
  function contrastRatio(l1, l2) {
    var lighter = Math.max(l1, l2);
    var darker = Math.min(l1, l2);
    return (lighter + 0.05) / (darker + 0.05);
  }

  var results = [];
  var pass = 0;
  var fail = 0;
  var selectors = 'p, span, a, button, label, li, td, th, h1, h2, h3, h4, h5, h6, div, strong, em, b, i, small';
  var elements = document.querySelectorAll(selectors);

  elements.forEach(function(el) {
    if (results.length > 200) return; // Limit output size
    var text = (el.textContent || '').trim();
    if (!text || text.length > 500) return;
    // Skip if this element has child elements with text (avoid double-counting)
    var directText = Array.from(el.childNodes).filter(function(n) { return n.nodeType === 3; }).map(function(n) { return n.textContent.trim(); }).join('');
    if (!directText) return;

    var style = window.getComputedStyle(el);
    var fg = parseColor(style.color);
    var bg = parseColor(style.backgroundColor);

    // Walk up DOM for background color if transparent
    if (bg && bg[0] === 0 && bg[1] === 0 && bg[2] === 0) {
      var parent = el.parentElement;
      while (parent) {
        var pBg = parseColor(window.getComputedStyle(parent).backgroundColor);
        if (pBg) {
          var pStyle = window.getComputedStyle(parent).backgroundColor;
          if (!pStyle.includes('rgba') || !pStyle.endsWith(', 0)')) {
            bg = pBg;
            break;
          }
        }
        parent = parent.parentElement;
      }
    }

    if (!fg || !bg) return;

    var fgL = luminance(fg[0], fg[1], fg[2]);
    var bgL = luminance(bg[0], bg[1], bg[2]);
    var ratio = contrastRatio(fgL, bgL);
    var fontSize = parseFloat(style.fontSize);
    var fontWeight = parseInt(style.fontWeight) || 400;
    var isLarge = fontSize >= 18 || (fontSize >= 14 && fontWeight >= 700);

    var aaMin = isLarge ? 3.0 : 4.5;
    var aaaMin = isLarge ? 4.5 : 7.0;
    var required = '${level}' === 'AAA' ? aaaMin : aaMin;
    var passes = ratio >= required;

    if (passes) {
      pass++;
    } else {
      fail++;
      results.push({
        element: el.tagName.toLowerCase() + (el.id ? '#'+el.id : '') + (el.className ? '.'+String(el.className).split(' ')[0] : ''),
        text: directText.substring(0, 80),
        foreground: style.color,
        background: style.backgroundColor,
        ratio: Math.round(ratio * 100) / 100,
        required: required,
        is_large_text: isLarge,
        font_size: fontSize + 'px',
        font_weight: fontWeight,
        passes: false,
      });
    }
  });

  return JSON.stringify({
    success: true,
    level: '${level}',
    pass_count: pass,
    fail_count: fail,
    failures: results,
    summary: pass + ' passed, ' + fail + ' failed',
  });
})()
''';
    final result = await cdp.eval(js);
    final value = result['result']?['value'] as String?;
    if (value != null) {
      return jsonDecode(value) as Map<String, dynamic>;
    }
    return {
      'success': false,
      'error': 'Failed to check contrast',
      'raw': result
    };
  }

  Future<Map<String, dynamic>> _handleA11yScreenReader(
      Map<String, dynamic> args) async {
    final cdp = _requireCdpForA11y();
    final maxElements = (args['max_elements'] as num?)?.toInt() ?? 100;

    try {
      // Build accessibility tree from DOM
      final axJs = '''
(function() {
  // Build accessibility info from DOM since we can't call CDP from JS
  var nodes = [];
  var walker = document.createTreeWalker(
    document.body,
    NodeFilter.SHOW_ELEMENT,
    null,
    false
  );

  var count = 0;
  var node = walker.currentNode;

  function getAccessibleName(el) {
    return el.getAttribute('aria-label')
      || el.getAttribute('alt')
      || el.getAttribute('title')
      || el.getAttribute('placeholder')
      || (el.labels && el.labels.length > 0 ? el.labels[0].textContent.trim() : null)
      || (el.textContent || '').trim().substring(0, 100)
      || null;
  }

  function getRole(el) {
    var explicit = el.getAttribute('role');
    if (explicit) return explicit;
    var tag = el.tagName.toLowerCase();
    var roleMap = {
      'a': el.hasAttribute('href') ? 'link' : null,
      'button': 'button',
      'input': el.type === 'checkbox' ? 'checkbox' : el.type === 'radio' ? 'radio' : el.type === 'range' ? 'slider' : 'textbox',
      'select': 'combobox',
      'textarea': 'textbox',
      'img': 'img',
      'nav': 'navigation',
      'main': 'main',
      'header': 'banner',
      'footer': 'contentinfo',
      'aside': 'complementary',
      'form': 'form',
      'table': 'table',
      'ul': 'list',
      'ol': 'list',
      'li': 'listitem',
      'h1': 'heading',
      'h2': 'heading',
      'h3': 'heading',
      'h4': 'heading',
      'h5': 'heading',
      'h6': 'heading',
      'dialog': 'dialog',
      'section': el.getAttribute('aria-label') || el.getAttribute('aria-labelledby') ? 'region' : null,
    };
    return roleMap[tag] || null;
  }

  while (node && count < $maxElements) {
    if (node.nodeType === 1) {
      var role = getRole(node);
      if (role) {
        var name = getAccessibleName(node);
        var value = node.value || null;
        var level = null;
        if (role === 'heading') {
          level = parseInt(node.tagName.charAt(1));
        }
        nodes.push({
          role: role,
          name: name,
          value: value,
          level: level,
          tag: node.tagName.toLowerCase(),
          id: node.id || null,
          'aria-expanded': node.getAttribute('aria-expanded'),
          'aria-checked': node.getAttribute('aria-checked'),
          'aria-selected': node.getAttribute('aria-selected'),
          'aria-disabled': node.getAttribute('aria-disabled'),
          'aria-hidden': node.getAttribute('aria-hidden'),
        });
        count++;
      }
    }
    node = walker.nextNode();
  }

  return JSON.stringify({
    success: true,
    elements: nodes,
    total: nodes.length,
    announcement_order: nodes.map(function(n) {
      var announcement = n.role;
      if (n.name) announcement += ': ' + n.name;
      if (n.value) announcement += ' (' + n.value + ')';
      if (n.level) announcement += ' level ' + n.level;
      return announcement;
    }),
  });
})()
''';
      final axResult = await cdp.eval(axJs);
      final value = axResult['result']?['value'] as String?;
      if (value != null) {
        return jsonDecode(value) as Map<String, dynamic>;
      }
      return {'success': false, 'error': 'Failed to build accessibility tree'};
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }
}
