import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';

/// Semantic fingerprint system for reliable element referencing.
/// Generates human-readable ref IDs in the format {role}:{content}[{index}]
class SemanticRefGenerator {
  // Element cache for performance optimization
  static final Map<String, Map<String, dynamic>> _elementCache = {};

  /// Clear the element cache
  static void clearCache() {
    _elementCache.clear();
  }

  /// Generate semantic ref ID for an element
  static String generateRefId(Element element, Map<String, int> refCounts) {
    final widget = element.widget;

    // Determine semantic role
    final role = _getSemanticRole(widget);

    // Extract content with priority: key > text/label/hint > tooltip > fallback
    String? content = _extractContent(element, widget);

    // Clean and format content
    if (content != null && content.isNotEmpty) {
      content = _sanitizeContent(content);

      final baseRef = '$role:$content';

      // Check for duplicates and add index if needed
      final count = refCounts[baseRef] ?? 0;
      refCounts[baseRef] = count + 1;

      if (count == 0) {
        return baseRef;
      } else {
        return '${baseRef}[$count]';
      }
    } else {
      // No content - use role + index fallback
      final count = refCounts[role] ?? 0;
      refCounts[role] = count + 1;
      return '${role}[$count]';
    }
  }

  /// Determine semantic role for a widget
  static String _getSemanticRole(Widget widget) {
    // Button family - all button-like widgets
    if (widget is ElevatedButton ||
        widget is TextButton ||
        widget is OutlinedButton ||
        widget is IconButton ||
        widget is FloatingActionButton ||
        widget is CupertinoButton) {
      return 'button';
    }

    // Input family - all text input widgets
    if (widget is TextField ||
        widget is TextFormField ||
        widget is CupertinoTextField ||
        widget is EditableText) {
      return 'input';
    }

    // Toggle family - switches and checkboxes
    if (widget is Switch ||
        widget is Checkbox ||
        widget is Radio ||
        widget is CupertinoSwitch ||
        (widget is ToggleButtons)) {
      return 'toggle';
    }

    // Slider family
    if (widget is Slider ||
        widget is RangeSlider ||
        widget is CupertinoSlider) {
      return 'slider';
    }

    // Select family - dropdowns and pickers
    if (widget is DropdownButton ||
        widget is PopupMenuButton ||
        widget is CupertinoActionSheet ||
        widget is CupertinoPicker) {
      return 'select';
    }

    // Link family - tappable text or links
    if ((widget is InkWell && _hasText(widget)) ||
        (widget is GestureDetector &&
            widget.onTap != null &&
            _hasTextInChildren(widget)) ||
        (widget is TextButton && widget.child is Text)) {
      return 'link';
    }

    // Item family - list items
    if (widget is ListTile || widget is Card || widget is ExpansionTile) {
      return 'item';
    }

    // Fallback for other interactive widgets
    return 'element';
  }

  /// Extract content from element with priority
  static String? _extractContent(Element element, Widget widget) {
    // Priority 1: ValueKey<String> - most stable
    if (widget.key is ValueKey<String>) {
      return (widget.key as ValueKey<String>).value;
    }

    // Priority 2: Widget-specific text/label/hint
    String? content = _getWidgetSpecificContent(widget);
    if (content != null && content.isNotEmpty) {
      return content;
    }

    // Priority 3: Extract text from child widgets
    content = _extractTextFromChildren(element);
    if (content != null && content.isNotEmpty) {
      return content;
    }

    // Priority 4: Tooltip
    if (widget is Tooltip) {
      return widget.message;
    }

    // Priority 5: Semantic label
    content = _extractSemanticLabel(element);
    if (content != null && content.isNotEmpty) {
      return content;
    }

    return null;
  }

  /// Get widget-specific content (text, label, hint, etc.)
  static String? _getWidgetSpecificContent(Widget widget) {
    // TextField family
    if (widget is TextField) {
      return widget.decoration?.labelText ??
          widget.decoration?.hintText ??
          widget.decoration?.helperText;
    }

    if (widget is TextFormField) {
      // TextFormField wraps a TextField, so we need to access it differently
      // This is a simplified approach - in practice we'd need to traverse the element tree
      return 'Text Field'; // Fallback for TextFormField
    }

    // Button family
    if (widget is ElevatedButton && widget.child is Text) {
      return (widget.child as Text).data;
    }

    if (widget is TextButton && widget.child is Text) {
      return (widget.child as Text).data;
    }

    if (widget is OutlinedButton && widget.child is Text) {
      return (widget.child as Text).data;
    }

    // Direct text widgets
    if (widget is Text) {
      return widget.data;
    }

    if (widget is RichText) {
      return widget.text.toPlainText();
    }

    // ListTile
    if (widget is ListTile) {
      if (widget.title is Text) {
        return (widget.title as Text).data;
      }
    }

    return null;
  }

  /// Extract text from child elements
  static String? _extractTextFromChildren(Element element) {
    String? foundText;

    void visit(Element child) {
      if (foundText != null) return;

      final widget = child.widget;
      if (widget is Text && widget.data != null) {
        foundText = widget.data;
        return;
      }

      if (widget is RichText) {
        foundText = widget.text.toPlainText();
        return;
      }

      child.visitChildren(visit);
    }

    element.visitChildren(visit);
    return foundText;
  }

  /// Extract semantic label from element
  static String? _extractSemanticLabel(Element element) {
    final widget = element.widget;
    if (widget is Semantics && widget.properties.label != null) {
      return widget.properties.label;
    }
    return null;
  }

  /// Sanitize content for use in ref IDs
  static String _sanitizeContent(String content) {
    // Replace spaces with underscores
    String sanitized = content.replaceAll(' ', '_');

    // Remove special characters, keep only alphanumeric and underscores
    sanitized = sanitized.replaceAll(RegExp(r'[^\w]'), '');

    // Truncate if too long
    if (sanitized.length > 30) {
      sanitized = '${sanitized.substring(0, 27)}...';
    }

    return sanitized;
  }

  /// Check if widget has text property
  static bool _hasText(Widget widget) {
    if (widget is InkWell) {
      return widget.child is Text;
    }
    return false;
  }

  /// Check if widget has text in its children (for GestureDetector)
  static bool _hasTextInChildren(Widget widget) {
    // This is a simplified check - in practice, we'd need to traverse children
    return true; // Conservative approach
  }

  /// Cache element data for performance
  static void cacheElement(
      String refId, Element element, Map<String, dynamic> bounds) {
    final weakRef = WeakReference(element);
    _elementCache[refId] = {
      'bounds': bounds,
      'element': weakRef,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };

    // Clean up old cache entries
    _cleanupCache();
  }

  /// Get cached element data
  static Map<String, dynamic>? getCachedElement(String refId) {
    final cached = _elementCache[refId];
    if (cached == null) return null;

    // Check if element is still valid
    final weakRef = cached['element'] as WeakReference<Element>?;
    if (weakRef?.target == null) {
      _elementCache.remove(refId);
      return null;
    }

    return cached;
  }

  /// Clean up stale cache entries
  static void _cleanupCache() {
    const maxCacheSize = 100;
    const maxCacheAge = 30000; // 30 seconds

    final now = DateTime.now().millisecondsSinceEpoch;

    // Remove stale entries
    _elementCache.removeWhere((key, value) {
      final timestamp = value['timestamp'] as int? ?? 0;
      final isStale = now - timestamp > maxCacheAge;

      final weakRef = value['element'] as WeakReference<Element>?;
      final isValid = weakRef?.target != null;

      return isStale || !isValid;
    });

    // If still too many entries, remove oldest
    if (_elementCache.length > maxCacheSize) {
      final entries = _elementCache.entries.toList();
      entries.sort((a, b) {
        final aTime = a.value['timestamp'] as int? ?? 0;
        final bTime = b.value['timestamp'] as int? ?? 0;
        return aTime.compareTo(bTime);
      });

      // Remove oldest 20%
      final toRemove = (entries.length * 0.2).round();
      for (int i = 0; i < toRemove; i++) {
        _elementCache.remove(entries[i].key);
      }
    }
  }

  /// Backward compatibility: check if ref looks like old format
  static bool isLegacyRef(String ref) {
    // Old format: btn_0, tf_1, sw_2, etc.
    // NOTE: elem_NNN is NOT a legacy ref — it's a numeric element ID from
    // get_interactable_elements and must NOT be handled by legacy parsing.
    if (ref.startsWith('elem_')) return false;
    return RegExp(r'^[a-z]+_\d+$').hasMatch(ref);
  }

  /// Convert legacy ref to search parameters for backward compatibility
  static Map<String, dynamic>? parseLegacyRef(String ref) {
    if (!isLegacyRef(ref)) return null;

    final parts = ref.split('_');
    if (parts.length != 2) return null;

    final prefix = parts[0];
    final index = int.tryParse(parts[1]);
    if (index == null) return null;

    // Map old prefixes to new roles for search fallback
    String? role;
    switch (prefix) {
      case 'btn':
        role = 'button';
        break;
      case 'tf':
        role = 'input';
        break;
      case 'sw':
        role = 'toggle';
        break;
      case 'sl':
        role = 'slider';
        break;
      case 'dd':
        role = 'select';
        break;
      case 'lnk':
        role = 'link';
        break;
      case 'item':
        role = 'item';
        break;
    }

    return {
      'role': role,
      'index': index,
      'legacy': true,
    };
  }
}
