part of '../server.dart';

extension _SelfHealingHandlers on FlutterMcpServer {
  Future<dynamic> _handleSelfHealingTools(
      String name, Map<String, dynamic> args) async {
    switch (name) {
      case 'smart_tap':
        return _smartTap(args);
      case 'smart_enter_text':
        return _smartEnterText(args);
      case 'smart_assert':
        return _smartAssert(args);
      default:
        return null;
    }
  }

  Future<Map<String, dynamic>> _smartTap(Map<String, dynamic> args) async {
    final cdp = _cdpDriver;
    if (cdp == null) {
      return {'success': false, 'error': 'No CDP connection'};
    }

    final key = args['key'] as String?;
    final text = args['text'] as String?;
    final ref = args['ref'] as String?;
    final strategy = args['heal_strategy'] as String? ?? 'moderate';

    // Strategy 1: exact key
    if (key != null) {
      try {
        final result = await cdp.tap(key: key);
        return {
          'success': true,
          'healed': false,
          'strategy_used': 'exact_key',
          'result': result,
        };
      } catch (_) {
        if (strategy == 'strict') {
          return {
            'success': false,
            'error': 'Element not found by key: $key',
            'healed': false
          };
        }
      }
    }

    // Strategy 2: text match
    if (text != null) {
      try {
        final result = await cdp.tap(text: text);
        return {
          'success': true,
          'healed': key != null,
          'strategy_used': 'text_match',
          'result': result,
        };
      } catch (_) {
        if (strategy == 'strict') {
          return {
            'success': false,
            'error': 'Element not found by text: $text',
            'healed': false
          };
        }
      }
    }

    // Strategy 3: semantic ref
    if (ref != null) {
      try {
        final result = await cdp.tap(ref: ref);
        return {
          'success': true,
          'healed': true,
          'strategy_used': 'semantic_ref',
          'result': result,
        };
      } catch (_) {}
    }

    // Strategy 4: fuzzy text match (moderate/aggressive)
    if (strategy != 'strict' && (text != null || key != null)) {
      final searchTerm = text ?? key ?? '';
      try {
        final elements = await cdp.getInteractiveElementsStructured();
        final elList = (elements['elements'] as List<dynamic>?) ?? [];

        _FuzzyMatch? bestMatch;
        for (final el in elList) {
          final elMap = el as Map<String, dynamic>;
          final elText = elMap['text']?.toString() ?? '';
          final elLabel = elMap['label']?.toString() ?? '';
          final elRef = elMap['ref']?.toString() ?? '';

          for (final candidate in [elText, elLabel, elRef]) {
            if (candidate.isEmpty) continue;
            final sim = _levenshteinSimilarity(
                searchTerm.toLowerCase(), candidate.toLowerCase());
            if (sim >= 0.8 &&
                (bestMatch == null || sim > bestMatch.similarity)) {
              bestMatch = _FuzzyMatch(
                  element: elMap, similarity: sim, matchedOn: candidate);
            }
          }
        }

        if (bestMatch != null) {
          // Tap the fuzzy-matched element
          final elRef = bestMatch.element['ref']?.toString();
          final elText = bestMatch.element['text']?.toString();
          final result = await cdp.tap(ref: elRef, text: elText);
          return {
            'success': true,
            'healed': true,
            'strategy_used': 'fuzzy_match',
            'matched_text': bestMatch.matchedOn,
            'similarity': bestMatch.similarity,
            'result': result,
          };
        }
      } catch (_) {}
    }

    return {
      'success': false,
      'error': 'Could not find element with any strategy',
      'healed': false,
      'tried': [
        if (key != null) 'exact_key',
        if (text != null) 'text_match',
        if (ref != null) 'semantic_ref',
        if (strategy != 'strict') 'fuzzy_match',
      ],
    };
  }

  Future<Map<String, dynamic>> _smartEnterText(
      Map<String, dynamic> args) async {
    final cdp = _cdpDriver;
    if (cdp == null) {
      return {'success': false, 'error': 'No CDP connection'};
    }

    final key = args['key'] as String?;
    final text = args['text'] as String?;
    final value = args['value'] as String? ?? '';
    final strategy = args['heal_strategy'] as String? ?? 'moderate';

    // Strategy 1: exact key
    if (key != null) {
      try {
        final result = await cdp.enterText(key, value);
        return {
          'success': true,
          'healed': false,
          'strategy_used': 'exact_key',
          'result': result
        };
      } catch (_) {
        if (strategy == 'strict') {
          return {
            'success': false,
            'error': 'Input not found by key: $key',
            'healed': false
          };
        }
      }
    }

    // Strategy 2: text/placeholder/label match
    if (text != null) {
      try {
        final result = await cdp.enterText(null, value, ref: 'input:$text');
        return {
          'success': true,
          'healed': key != null,
          'strategy_used': 'text_match',
          'result': result
        };
      } catch (_) {}

      // Try finding input by placeholder or label
      try {
        final elements = await cdp.getInteractiveElementsStructured();
        final elList = (elements['elements'] as List<dynamic>?) ?? [];
        for (final el in elList) {
          final elMap = el as Map<String, dynamic>;
          final actions = (elMap['actions'] as List?)?.cast<String>() ?? [];
          if (!actions.contains('enter_text')) continue;

          final elText = elMap['text']?.toString() ?? '';
          final elLabel = elMap['label']?.toString() ?? '';
          final elPlaceholder = elMap['placeholder']?.toString() ?? '';

          if (elText.toLowerCase().contains(text.toLowerCase()) ||
              elLabel.toLowerCase().contains(text.toLowerCase()) ||
              elPlaceholder.toLowerCase().contains(text.toLowerCase())) {
            final elRef = elMap['ref']?.toString();
            final result = await cdp.enterText(null, value, ref: elRef);
            return {
              'success': true,
              'healed': true,
              'strategy_used': 'label_match',
              'matched_label': elLabel.isNotEmpty ? elLabel : elText,
              'result': result
            };
          }
        }
      } catch (_) {}
    }

    // Strategy 3: fuzzy match
    if (strategy != 'strict') {
      final searchTerm = text ?? key ?? '';
      if (searchTerm.isNotEmpty) {
        try {
          final elements = await cdp.getInteractiveElementsStructured();
          final elList = (elements['elements'] as List<dynamic>?) ?? [];

          _FuzzyMatch? bestMatch;
          for (final el in elList) {
            final elMap = el as Map<String, dynamic>;
            final actions = (elMap['actions'] as List?)?.cast<String>() ?? [];
            if (!actions.contains('enter_text')) continue;

            for (final field in ['text', 'label', 'placeholder', 'ref']) {
              final candidate = elMap[field]?.toString() ?? '';
              if (candidate.isEmpty) continue;
              final sim = _levenshteinSimilarity(
                  searchTerm.toLowerCase(), candidate.toLowerCase());
              if (sim >= 0.8 &&
                  (bestMatch == null || sim > bestMatch.similarity)) {
                bestMatch = _FuzzyMatch(
                    element: elMap, similarity: sim, matchedOn: candidate);
              }
            }
          }

          if (bestMatch != null) {
            final elRef = bestMatch.element['ref']?.toString();
            final result = await cdp.enterText(null, value, ref: elRef);
            return {
              'success': true,
              'healed': true,
              'strategy_used': 'fuzzy_match',
              'matched_text': bestMatch.matchedOn,
              'similarity': bestMatch.similarity,
              'result': result,
            };
          }
        } catch (_) {}
      }
    }

    return {
      'success': false,
      'error': 'Could not find input with any strategy',
      'healed': false,
    };
  }

  Future<Map<String, dynamic>> _smartAssert(Map<String, dynamic> args) async {
    final cdp = _cdpDriver;
    if (cdp == null) {
      return {'success': false, 'error': 'No CDP connection'};
    }

    final type = args['type'] as String? ?? 'visible';
    final key = args['key'] as String?;
    final text = args['text'] as String?;
    final expected = args['expected'];
    final tolerance = (args['tolerance'] as num?)?.toDouble() ?? 0.8;

    switch (type) {
      case 'visible':
        // Check if element is visible, with healing
        final searchTerm = text ?? key ?? '';
        try {
          final elements = await cdp.getInteractiveElementsStructured();
          final elList = (elements['elements'] as List<dynamic>?) ?? [];

          // Exact match
          for (final el in elList) {
            final elMap = el as Map<String, dynamic>;
            final elText = elMap['text']?.toString() ?? '';
            final elRef = elMap['ref']?.toString() ?? '';
            if (elText == searchTerm ||
                elRef == searchTerm ||
                (key != null && elMap['key'] == key)) {
              return {
                'success': true,
                'visible': true,
                'healed': false,
                'strategy_used': 'exact'
              };
            }
          }

          // Fuzzy match
          _FuzzyMatch? best;
          for (final el in elList) {
            final elMap = el as Map<String, dynamic>;
            for (final f in ['text', 'label', 'ref']) {
              final c = elMap[f]?.toString() ?? '';
              if (c.isEmpty) continue;
              final sim = _levenshteinSimilarity(
                  searchTerm.toLowerCase(), c.toLowerCase());
              if (sim >= tolerance && (best == null || sim > best.similarity)) {
                best =
                    _FuzzyMatch(element: elMap, similarity: sim, matchedOn: c);
              }
            }
          }

          if (best != null) {
            return {
              'success': true,
              'visible': true,
              'healed': true,
              'strategy_used': 'fuzzy',
              'matched_text': best.matchedOn,
              'similarity': best.similarity,
            };
          }

          return {'success': true, 'visible': false, 'healed': false};
        } catch (e) {
          return {'success': false, 'error': e.toString()};
        }

      case 'text':
        // Assert text content with fuzzy matching
        final expectedStr = expected?.toString() ?? '';
        try {
          final elements = await cdp.getInteractiveElementsStructured();
          final elList = (elements['elements'] as List<dynamic>?) ?? [];

          for (final el in elList) {
            final elMap = el as Map<String, dynamic>;
            if (key != null && elMap['key'] != key && elMap['ref'] != key)
              continue;
            if (text != null && elMap['text'] != text) continue;

            final actual =
                elMap['text']?.toString() ?? elMap['value']?.toString() ?? '';

            // Exact match
            if (actual == expectedStr) {
              return {
                'success': true,
                'match': true,
                'healed': false,
                'actual': actual
              };
            }

            // Normalized whitespace match
            final normActual = actual.replaceAll(RegExp(r'\s+'), ' ').trim();
            final normExpected =
                expectedStr.replaceAll(RegExp(r'\s+'), ' ').trim();
            if (normActual == normExpected) {
              return {
                'success': true,
                'match': true,
                'healed': true,
                'strategy_used': 'normalized_whitespace',
                'actual': actual
              };
            }

            // Partial text match
            if (normActual.contains(normExpected) ||
                normExpected.contains(normActual)) {
              return {
                'success': true,
                'match': true,
                'healed': true,
                'strategy_used': 'partial_match',
                'actual': actual
              };
            }

            // Fuzzy match
            final sim = _levenshteinSimilarity(
                normActual.toLowerCase(), normExpected.toLowerCase());
            if (sim >= tolerance) {
              return {
                'success': true,
                'match': true,
                'healed': true,
                'strategy_used': 'fuzzy',
                'similarity': sim,
                'actual': actual,
              };
            }

            return {
              'success': true,
              'match': false,
              'actual': actual,
              'expected': expectedStr
            };
          }

          return {'success': false, 'error': 'Element not found'};
        } catch (e) {
          return {'success': false, 'error': e.toString()};
        }

      case 'count':
        final expectedCount = (expected is int)
            ? expected
            : int.tryParse(expected?.toString() ?? '');
        try {
          final elements = await cdp.getInteractiveElementsStructured();
          final elList = (elements['elements'] as List<dynamic>?) ?? [];
          final matchingCount = text != null
              ? elList
                  .where((e) =>
                      (e as Map)['text']?.toString().contains(text) == true)
                  .length
              : elList.length;
          return {
            'success': true,
            'match': matchingCount == expectedCount,
            'actual_count': matchingCount,
            'expected_count': expectedCount,
          };
        } catch (e) {
          return {'success': false, 'error': e.toString()};
        }

      default:
        return {'success': false, 'error': 'Unknown assert type: $type'};
    }
  }
}

class _FuzzyMatch {
  final Map<String, dynamic> element;
  final double similarity;
  final String matchedOn;

  _FuzzyMatch(
      {required this.element,
      required this.similarity,
      required this.matchedOn});
}

/// Levenshtein distance — pure Dart dynamic programming implementation.
int _levenshteinDistance(String a, String b) {
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;

  final m = a.length;
  final n = b.length;

  // Use single-row optimization
  var prev = List<int>.generate(n + 1, (i) => i);
  var curr = List<int>.filled(n + 1, 0);

  for (var i = 1; i <= m; i++) {
    curr[0] = i;
    for (var j = 1; j <= n; j++) {
      final cost = a[i - 1] == b[j - 1] ? 0 : 1;
      curr[j] = [
        prev[j] + 1, // deletion
        curr[j - 1] + 1, // insertion
        prev[j - 1] + cost, // substitution
      ].reduce((a, b) => a < b ? a : b);
    }
    final tmp = prev;
    prev = curr;
    curr = tmp;
  }

  return prev[n];
}

/// Similarity score between 0.0 and 1.0 based on Levenshtein distance.
double _levenshteinSimilarity(String a, String b) {
  if (a.isEmpty && b.isEmpty) return 1.0;
  final maxLen = a.length > b.length ? a.length : b.length;
  if (maxLen == 0) return 1.0;
  return 1.0 - (_levenshteinDistance(a, b) / maxLen);
}
