part of '../server.dart';

extension _DiffHandlers on FlutterMcpServer {
  Future<dynamic> _handleDiffTools(
      String name, Map<String, dynamic> args) async {
    switch (name) {
      case 'diff_baseline_create':
        return await _diffBaselineCreate(args);
      case 'diff_compare':
        return await _diffCompare(args);
      case 'diff_pages':
        return await _diffPages(args);
      default:
        return null;
    }
  }

  /// Create a baseline snapshot of all discovered pages.
  Future<Map<String, dynamic>> _diffBaselineCreate(
      Map<String, dynamic> args) async {
    final cdp = _cdpDriver;
    if (cdp == null || !cdp.isConnected) {
      return {
        'success': false,
        'error': 'CDP not connected. Use connect_cdp first.'
      };
    }

    final baselinePath = args['path'] as String? ?? './.flutter-skill-baseline';
    final depth = args['depth'] as int? ?? 2;
    final maxPages = args['max_pages'] as int? ?? 10;

    final dir = Directory(baselinePath);
    if (!dir.existsSync()) await dir.create(recursive: true);

    // Get current URL as starting point
    final startUrlResult = await cdp.eval('window.location.href');
    final startUrl = startUrlResult['result']?['value'] as String?;
    if (startUrl == null) {
      return {'success': false, 'error': 'Cannot determine current URL'};
    }

    // Discover pages
    final pages =
        await _diffDiscoverPages(cdp, startUrl, depth, maxPages: maxPages);
    final savedPages = <String>[];

    for (final page in pages) {
      try {
        await cdp.navigate(page);
        await Future.delayed(const Duration(seconds: 1));

        final safeName = _diffSafeFileName(page);

        // Screenshot
        final screenshot = await cdp.takeScreenshot(quality: 1.0);
        if (screenshot != null) {
          final file = File('$baselinePath/$safeName.png');
          await file.writeAsBytes(base64.decode(screenshot));
        }

        // Snapshot
        final snapshot = await _diffGetPageSnapshot(cdp);
        final snapshotFile = File('$baselinePath/$safeName.json');
        await snapshotFile.writeAsString(jsonEncode(snapshot));

        savedPages.add(page);
      } catch (e) {
        // Skip failed pages
      }
    }

    // Navigate back to original page
    await cdp.navigate(startUrl);

    return {
      'success': true,
      'baseline_path': baselinePath,
      'pages_saved': savedPages.length,
      'pages': savedPages,
    };
  }

  /// Compare current state against a saved baseline.
  Future<Map<String, dynamic>> _diffCompare(Map<String, dynamic> args) async {
    final cdp = _cdpDriver;
    if (cdp == null || !cdp.isConnected) {
      return {
        'success': false,
        'error': 'CDP not connected. Use connect_cdp first.'
      };
    }

    final baselinePath =
        args['baseline_path'] as String? ?? './.flutter-skill-baseline';
    final threshold = (args['threshold'] as num?)?.toDouble() ?? 0.05;

    final dir = Directory(baselinePath);
    if (!dir.existsSync()) {
      return {
        'success': false,
        'error':
            'Baseline not found at $baselinePath. Use diff_baseline_create first.',
      };
    }

    final startUrlResult2 = await cdp.eval('window.location.href');
    final startUrl = startUrlResult2['result']?['value'] as String?;
    if (startUrl == null) {
      return {'success': false, 'error': 'Cannot determine current URL'};
    }

    // Discover current pages
    final maxPages = args['max_pages'] as int? ?? 10;
    final pages =
        await _diffDiscoverPages(cdp, startUrl, 2, maxPages: maxPages);
    final results = <Map<String, dynamic>>[];
    int changedCount = 0;

    for (final page in pages) {
      try {
        await cdp.navigate(page);
        await Future.delayed(const Duration(seconds: 1));

        final safeName = _diffSafeFileName(page);
        final changes = <String>[];

        // Load baseline snapshot
        final baselineFile = File('$baselinePath/$safeName.json');
        if (!baselineFile.existsSync()) {
          changes.add('New page (not in baseline)');
        } else {
          final baselineSnapshot = jsonDecode(await baselineFile.readAsString())
              as Map<String, dynamic>;
          final currentSnapshot = await _diffGetPageSnapshot(cdp);

          // Element count changes
          final bElements = baselineSnapshot['elementCount'] as int? ?? 0;
          final cElements = currentSnapshot['elementCount'] as int? ?? 0;
          if (bElements != cElements) {
            final diff = cElements - bElements;
            changes.add(
                'Elements: $bElements → $cElements (${diff > 0 ? "+$diff" : "$diff"})');
          }

          // Button count
          final bButtons = baselineSnapshot['buttonCount'] as int? ?? 0;
          final cButtons = currentSnapshot['buttonCount'] as int? ?? 0;
          if (bButtons != cButtons) {
            changes.add('Buttons: $bButtons → $cButtons');
          }

          // Link count
          final bLinks = baselineSnapshot['linkCount'] as int? ?? 0;
          final cLinks = currentSnapshot['linkCount'] as int? ?? 0;
          if (bLinks != cLinks) {
            changes.add('Links: $bLinks → $cLinks');
          }

          // Input count
          final bInputs = baselineSnapshot['inputCount'] as int? ?? 0;
          final cInputs = currentSnapshot['inputCount'] as int? ?? 0;
          if (bInputs != cInputs) {
            changes.add('Inputs: $bInputs → $cInputs');
          }

          // Performance
          final bLoad = baselineSnapshot['loadTimeMs'] as int?;
          final cLoad = currentSnapshot['loadTimeMs'] as int?;
          if (bLoad != null && cLoad != null && (cLoad - bLoad).abs() > 500) {
            changes.add('Load time: ${bLoad}ms → ${cLoad}ms');
          }

          // Screenshot diff
          final baselineScreenshotFile = File('$baselinePath/$safeName.png');
          if (baselineScreenshotFile.existsSync()) {
            final currentScreenshot = await cdp.takeScreenshot(quality: 1.0);
            if (currentScreenshot != null) {
              final currentBytes = base64.decode(currentScreenshot);
              final baselineBytes = await baselineScreenshotFile.readAsBytes();
              final diffPercent =
                  _diffPixelCompare(currentBytes, baselineBytes);
              if (diffPercent > threshold * 100) {
                changes.add(
                    'Visual diff: ${diffPercent.toStringAsFixed(2)}% pixels changed');
              }
            }
          }
        }

        if (changes.isNotEmpty) changedCount++;

        results.add({
          'url': page,
          'status': changes.isEmpty ? 'unchanged' : 'changed',
          'changes': changes,
        });
      } catch (e) {
        results.add({
          'url': page,
          'status': 'error',
          'changes': ['Error: $e'],
        });
      }
    }

    // Navigate back
    await cdp.navigate(startUrl);

    return {
      'success': true,
      'total_pages': results.length,
      'changed_pages': changedCount,
      'unchanged_pages': results.length - changedCount,
      'results': results,
    };
  }

  /// Compare two specific URLs side by side.
  Future<Map<String, dynamic>> _diffPages(Map<String, dynamic> args) async {
    final cdp = _cdpDriver;
    if (cdp == null || !cdp.isConnected) {
      return {
        'success': false,
        'error': 'CDP not connected. Use connect_cdp first.'
      };
    }

    final urlA = args['url_a'] as String?;
    final urlB = args['url_b'] as String?;
    if (urlA == null || urlB == null) {
      return {'success': false, 'error': 'Both url_a and url_b are required'};
    }

    // Capture page A
    await cdp.navigate(urlA);
    await Future.delayed(const Duration(seconds: 1));
    final snapshotA = await _diffGetPageSnapshot(cdp);
    final screenshotA = await cdp.takeScreenshot(quality: 0.8);

    // Capture page B
    await cdp.navigate(urlB);
    await Future.delayed(const Duration(seconds: 1));
    final snapshotB = await _diffGetPageSnapshot(cdp);
    final screenshotB = await cdp.takeScreenshot(quality: 0.8);

    // Compare
    final differences = <String>[];

    // Element counts
    final eA = snapshotA['elementCount'] as int? ?? 0;
    final eB = snapshotB['elementCount'] as int? ?? 0;
    if (eA != eB) differences.add('Element count: $eA vs $eB');

    final bA = snapshotA['buttonCount'] as int? ?? 0;
    final bB = snapshotB['buttonCount'] as int? ?? 0;
    if (bA != bB) differences.add('Buttons: $bA vs $bB');

    final lA = snapshotA['linkCount'] as int? ?? 0;
    final lB = snapshotB['linkCount'] as int? ?? 0;
    if (lA != lB) differences.add('Links: $lA vs $lB');

    final iA = snapshotA['inputCount'] as int? ?? 0;
    final iB = snapshotB['inputCount'] as int? ?? 0;
    if (iA != iB) differences.add('Inputs: $iA vs $iB');

    // Pixel diff
    double? pixelDiff;
    if (screenshotA != null && screenshotB != null) {
      pixelDiff = _diffPixelCompare(
          base64.decode(screenshotA), base64.decode(screenshotB));
      if (pixelDiff > 5.0) {
        differences.add('Visual diff: ${pixelDiff.toStringAsFixed(2)}%');
      }
    }

    return {
      'success': true,
      'url_a': urlA,
      'url_b': urlB,
      'identical': differences.isEmpty,
      'differences': differences,
      'page_a': {
        'title': snapshotA['title'],
        'elements': snapshotA['elementCount'],
        'buttons': snapshotA['buttonCount'],
        'links': snapshotA['linkCount'],
        'inputs': snapshotA['inputCount'],
      },
      'page_b': {
        'title': snapshotB['title'],
        'elements': snapshotB['elementCount'],
        'buttons': snapshotB['buttonCount'],
        'links': snapshotB['linkCount'],
        'inputs': snapshotB['inputCount'],
      },
      if (pixelDiff != null) 'pixel_diff_percent': pixelDiff,
    };
  }

  // --- Helpers ---

  Future<List<String>> _diffDiscoverPages(
      CdpDriver cdp, String startUrl, int maxDepth,
      {int maxPages = 10}) async {
    final visited = <String>{};
    final toVisit = <String>[startUrl];
    final baseUri = Uri.parse(startUrl);

    for (var d = 0; d < maxDepth && toVisit.isNotEmpty; d++) {
      final batch = List<String>.from(toVisit);
      toVisit.clear();

      for (final pageUrl in batch) {
        if (visited.length >= maxPages) break;
        if (visited.contains(pageUrl)) continue;
        visited.add(pageUrl);

        try {
          await cdp.navigate(pageUrl);
          await Future.delayed(const Duration(milliseconds: 500));

          final linksRaw = await cdp.eval('''
            JSON.stringify(
              Array.from(document.querySelectorAll('a[href]'))
                .map(a => a.href)
                .filter(h => h.startsWith('http'))
            )
          ''');
          final linksJson = linksRaw['result']?['value'] as String?;
          final linksList = linksJson != null
              ? (jsonDecode(linksJson) as List).cast<String>()
              : <String>[];

          if (linksList.isNotEmpty) {
            for (final link in linksList) {
              final linkUri = Uri.tryParse(link.toString());
              if (linkUri != null &&
                  linkUri.host == baseUri.host &&
                  !visited.contains(link.toString())) {
                final clean = linkUri
                    .replace(fragment: '')
                    .toString()
                    .replaceAll('#', '');
                if (!visited.contains(clean)) toVisit.add(clean);
              }
            }
          }
        } catch (_) {}
      }
    }

    return visited.toList();
  }

  Future<Map<String, dynamic>> _diffGetPageSnapshot(CdpDriver cdp) async {
    final result = await cdp.eval('''
      JSON.stringify((() => {
        const elements = [];
        document.querySelectorAll(
          'a, button, input, select, textarea, [role="button"], [role="link"], [onclick]'
        ).forEach(el => {
          const rect = el.getBoundingClientRect();
          elements.push({
            tag: el.tagName.toLowerCase(),
            type: el.type || null,
            text: (el.textContent || '').trim().substring(0, 100),
            href: el.href || null,
            id: el.id || null,
            visible: rect.width > 0 && rect.height > 0,
          });
        });
        const perf = window.performance.timing;
        return {
          title: document.title,
          url: window.location.href,
          textContent: document.body ? document.body.innerText.substring(0, 5000) : '',
          elements: elements,
          elementCount: elements.length,
          buttonCount: elements.filter(e => e.tag === 'button' || e.role === 'button').length,
          linkCount: elements.filter(e => e.tag === 'a').length,
          inputCount: elements.filter(e => ['input','select','textarea'].includes(e.tag)).length,
          loadTimeMs: perf.loadEventEnd > 0 ? perf.loadEventEnd - perf.navigationStart : null,
          timestamp: Date.now(),
        };
      })())
    ''');
    final jsonStr = result['result']?['value'] as String?;
    if (jsonStr != null) return Map<String, dynamic>.from(jsonDecode(jsonStr));
    return {};
  }

  String _diffSafeFileName(String url) {
    return url
        .replaceAll(RegExp(r'https?://'), '')
        .replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
  }

  double _diffPixelCompare(List<int> a, List<int> b) {
    if (a.isEmpty || b.isEmpty) return 100.0;
    final minLen = a.length < b.length ? a.length : b.length;
    final maxLen = a.length > b.length ? a.length : b.length;
    int diffCount = 0;
    for (var i = 0; i < minLen; i++) {
      if (a[i] != b[i]) diffCount++;
    }
    diffCount += (maxLen - minLen);
    return (diffCount / maxLen) * 100;
  }
}
