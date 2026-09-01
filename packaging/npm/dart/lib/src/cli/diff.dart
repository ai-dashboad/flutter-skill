import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../bridge/cdp_driver.dart';

/// `flutter-skill diff` — Diff Testing: compare current app state against a baseline.
///
/// Usage:
///   flutter-skill diff https://my-app.com --baseline=./baseline [--report=diff-report.html]
Future<void> runDiff(List<String> args) async {
  String? url;
  String baselinePath = './.flutter-skill-baseline';
  String reportPath = 'diff-report.html';
  int cdpPort = 0; // 0 = auto-assign random port
  bool headless = true;
  int depth = 2;
  double threshold = 0.05;
  int maxPages = 10;

  for (final arg in args) {
    if (arg.startsWith('--baseline=')) {
      baselinePath = arg.substring(11);
    } else if (arg.startsWith('--report=')) {
      reportPath = arg.substring(9);
    } else if (arg.startsWith('--cdp-port=')) {
      cdpPort = int.parse(arg.substring(11));
    } else if (arg == '--no-headless') {
      headless = false;
    } else if (arg.startsWith('--depth=')) {
      depth = int.parse(arg.substring(8));
    } else if (arg.startsWith('--threshold=')) {
      threshold = double.parse(arg.substring(12));
    } else if (arg.startsWith('--max-pages=')) {
      maxPages = int.parse(arg.substring(12));
    } else if (!arg.startsWith('-')) {
      url = arg;
    }
  }

  if (url == null) {
    print('Usage: flutter-skill diff <url> [options]');
    print('');
    print('Options:');
    print(
        '  --baseline=PATH    Baseline directory (default: ./.flutter-skill-baseline)');
    print(
        '  --report=PATH      HTML report output path (default: diff-report.html)');
    print('  --cdp-port=N       Chrome DevTools port (default: 9222)');
    print('  --depth=N          Max crawl depth (default: 2)');
    print('  --threshold=N      Pixel diff threshold 0-1 (default: 0.05)');
    print('  --no-headless      Run Chrome with UI visible');
    print('  --max-pages=N      Max pages to visit (default: 10)');
    exit(1);
  }

  print('🔍 flutter-skill diff — Diff Testing');
  print('');
  print('   URL: $url');
  print('   Baseline: $baselinePath');
  print('   Report: $reportPath');
  print('   Depth: $depth');
  print('   Threshold: $threshold');
  print('');

  final baselineDir = Directory(baselinePath);
  final baselineExists = baselineDir.existsSync();

  // Launch Chrome and connect via CDP
  final cdp = CdpDriver(
    url: url,
    port: cdpPort,
    launchChrome: cdpPort == 0,
    headless: headless,
  );
  try {
    await cdp.connect();
    await Future.delayed(const Duration(seconds: 2));

    // Discover pages
    print('🕷️  Discovering pages (depth: $depth)...');
    final pages = await _discoverPages(cdp, url, depth, maxPages: maxPages);
    print('   Found ${pages.length} pages');

    if (!baselineExists) {
      // Create baseline
      print('');
      print('📸 Creating baseline (no existing baseline found)...');
      await baselineDir.create(recursive: true);

      for (var i = 0; i < pages.length; i++) {
        final page = pages[i];
        print('   [${i + 1}/${pages.length}] $page');
        await cdp.navigate(page);
        await Future.delayed(const Duration(seconds: 1));

        final safeName = _safeFileName(page);

        // Screenshot
        final screenshot = await cdp.takeScreenshot(quality: 1.0);
        if (screenshot != null) {
          final file = File('$baselinePath/$safeName.png');
          await file.writeAsBytes(base64.decode(screenshot));
        }

        // Snapshot (text representation)
        final snapshot = await _getPageSnapshot(cdp);
        final snapshotFile = File('$baselinePath/$safeName.json');
        await snapshotFile.writeAsString(jsonEncode(snapshot));
      }

      print('');
      print('✅ Baseline created at $baselinePath');
      print('   Run the same command again to compare against this baseline.');
    } else {
      // Compare against baseline
      print('');
      print('⚖️  Comparing against baseline...');

      final results = <Map<String, dynamic>>[];

      for (var i = 0; i < pages.length; i++) {
        final page = pages[i];
        print('   [${i + 1}/${pages.length}] $page');
        await cdp.navigate(page);
        await Future.delayed(const Duration(seconds: 1));

        final safeName = _safeFileName(page);
        final result = await _comparePage(
          cdp,
          baselinePath,
          safeName,
          page,
          threshold,
        );
        results.add(result);
      }

      // Check for pages in baseline that no longer exist
      final baselineFiles = baselineDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .map((f) => f.uri.pathSegments.last.replaceAll('.json', ''))
          .toSet();
      final currentPages = pages.map(_safeFileName).toSet();
      final removedPages = baselineFiles.difference(currentPages);
      for (final removed in removedPages) {
        results.add({
          'page': removed,
          'url': removed,
          'status': 'removed',
          'changes': ['Page no longer exists'],
        });
      }

      // Generate report
      print('');
      print('📊 Generating report...');
      await _generateDiffReport(results, reportPath, baselinePath);
      print('   Report saved to: $reportPath');

      // Summary
      final changed = results.where((r) => r['status'] != 'unchanged').length;
      final total = results.length;
      print('');
      if (changed == 0) {
        print('✅ No differences found ($total pages checked)');
      } else {
        print('⚠️  $changed/$total pages have differences');
        for (final r in results.where((r) => r['status'] != 'unchanged')) {
          final changes = (r['changes'] as List?)?.length ?? 0;
          print('   • ${r['url']}: $changes changes (${r['status']})');
        }
      }
    }
  } finally {
    await cdp.disconnect();
  }
}

/// Discover pages by crawling links
Future<List<String>> _discoverPages(
    CdpDriver cdp, String startUrl, int maxDepth,
    {int maxPages = 10}) async {
  final visited = <String>{};
  final toVisit = <String>[startUrl];
  final baseUri = Uri.parse(startUrl);

  for (var depth = 0; depth < maxDepth && toVisit.isNotEmpty; depth++) {
    final currentBatch = List<String>.from(toVisit);
    toVisit.clear();

    for (final pageUrl in currentBatch) {
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
              // Strip fragments
              final clean =
                  linkUri.replace(fragment: '').toString().replaceAll('#', '');
              if (!visited.contains(clean)) {
                toVisit.add(clean);
              }
            }
          }
        }
      } catch (_) {
        // Skip pages that fail to load
      }
    }
  }

  return visited.toList();
}

/// Get a structured snapshot of the current page
Future<Map<String, dynamic>> _getPageSnapshot(CdpDriver cdp) async {
  final result = await cdp.eval('''
    JSON.stringify((() => {
      const elements = [];
      const interactive = document.querySelectorAll(
        'a, button, input, select, textarea, [role="button"], [role="link"], [onclick]'
      );
      interactive.forEach(el => {
        const rect = el.getBoundingClientRect();
        elements.push({
          tag: el.tagName.toLowerCase(),
          type: el.type || null,
          text: (el.textContent || '').trim().substring(0, 100),
          href: el.href || null,
          id: el.id || null,
          name: el.name || null,
          role: el.getAttribute('role') || null,
          visible: rect.width > 0 && rect.height > 0,
          x: Math.round(rect.x),
          y: Math.round(rect.y),
          width: Math.round(rect.width),
          height: Math.round(rect.height),
        });
      });

      const title = document.title;
      const url = window.location.href;
      const textContent = document.body ? document.body.innerText.substring(0, 5000) : '';
      const perf = window.performance.timing;
      const loadTime = perf.loadEventEnd - perf.navigationStart;

      return {
        title: title,
        url: url,
        textContent: textContent,
        elements: elements,
        elementCount: elements.length,
        buttonCount: elements.filter(e => e.tag === 'button' || e.role === 'button').length,
        linkCount: elements.filter(e => e.tag === 'a').length,
        inputCount: elements.filter(e => ['input','select','textarea'].includes(e.tag)).length,
        loadTimeMs: loadTime > 0 ? loadTime : null,
        timestamp: Date.now(),
      };
    })())
  ''');

  final jsonStr = result['result']?['value'] as String?;
  if (jsonStr != null) {
    return Map<String, dynamic>.from(jsonDecode(jsonStr));
  }
  return {'error': 'Failed to capture snapshot'};
}

/// Compare a page against its baseline
Future<Map<String, dynamic>> _comparePage(
  CdpDriver cdp,
  String baselinePath,
  String safeName,
  String pageUrl,
  double threshold,
) async {
  final changes = <String>[];
  final details = <String, dynamic>{};

  // Get current snapshot
  final currentSnapshot = await _getPageSnapshot(cdp);

  // Load baseline snapshot
  final baselineFile = File('$baselinePath/$safeName.json');
  Map<String, dynamic>? baselineSnapshot;
  if (baselineFile.existsSync()) {
    try {
      baselineSnapshot =
          jsonDecode(await baselineFile.readAsString()) as Map<String, dynamic>;
    } catch (_) {}
  }

  // Screenshot comparison
  final baselineScreenshot = File('$baselinePath/$safeName.png');
  if (baselineScreenshot.existsSync()) {
    final currentScreenshot = await cdp.takeScreenshot(quality: 1.0);
    if (currentScreenshot != null) {
      final currentBytes = base64.decode(currentScreenshot);
      final baselineBytes = await baselineScreenshot.readAsBytes();
      final diffPercent = _pixelDiff(currentBytes, baselineBytes);
      details['pixel_diff_percent'] = diffPercent;
      if (diffPercent > threshold * 100) {
        changes.add(
            'Visual difference: ${diffPercent.toStringAsFixed(2)}% pixels changed');
      }

      // Save current screenshot for report
      final currentFile = File('$baselinePath/${safeName}_current.png');
      await currentFile.writeAsBytes(currentBytes);
      details['current_screenshot'] = currentFile.path;
      details['baseline_screenshot'] = baselineScreenshot.path;
    }
  } else {
    changes.add('New page (no baseline screenshot)');
  }

  // Snapshot text comparison
  if (baselineSnapshot != null) {
    // Element count changes
    final baselineElements = baselineSnapshot['elementCount'] as int? ?? 0;
    final currentElements = currentSnapshot['elementCount'] as int? ?? 0;
    if (baselineElements != currentElements) {
      final diff = currentElements - baselineElements;
      changes.add(
          'Element count: $baselineElements → $currentElements (${diff > 0 ? "+$diff" : "$diff"})');
    }

    // Button count
    final baselineButtons = baselineSnapshot['buttonCount'] as int? ?? 0;
    final currentButtons = currentSnapshot['buttonCount'] as int? ?? 0;
    if (baselineButtons != currentButtons) {
      changes.add('Buttons: $baselineButtons → $currentButtons');
    }

    // Link count
    final baselineLinks = baselineSnapshot['linkCount'] as int? ?? 0;
    final currentLinks = currentSnapshot['linkCount'] as int? ?? 0;
    if (baselineLinks != currentLinks) {
      changes.add('Links: $baselineLinks → $currentLinks');
    }

    // Input count
    final baselineInputs = baselineSnapshot['inputCount'] as int? ?? 0;
    final currentInputs = currentSnapshot['inputCount'] as int? ?? 0;
    if (baselineInputs != currentInputs) {
      changes.add('Inputs: $baselineInputs → $currentInputs');
    }

    // Performance comparison
    final baselineLoad = baselineSnapshot['loadTimeMs'] as int?;
    final currentLoad = currentSnapshot['loadTimeMs'] as int?;
    if (baselineLoad != null && currentLoad != null) {
      final diff = currentLoad - baselineLoad;
      if (diff.abs() > 500) {
        changes.add(
            'Load time: ${baselineLoad}ms → ${currentLoad}ms (${diff > 0 ? "+${diff}ms slower" : "${diff}ms faster"})');
      }
      details['load_time_baseline'] = baselineLoad;
      details['load_time_current'] = currentLoad;
    }

    // Text content diff
    final baselineText = baselineSnapshot['textContent'] as String? ?? '';
    final currentText = currentSnapshot['textContent'] as String? ?? '';
    if (baselineText != currentText) {
      final addedLines = <String>[];
      final removedLines = <String>[];
      final bLines = baselineText.split('\n').toSet();
      final cLines = currentText.split('\n').toSet();
      for (final line in cLines.difference(bLines)) {
        if (line.trim().isNotEmpty) addedLines.add(line.trim());
      }
      for (final line in bLines.difference(cLines)) {
        if (line.trim().isNotEmpty) removedLines.add(line.trim());
      }
      if (addedLines.isNotEmpty || removedLines.isNotEmpty) {
        changes.add(
            'Text content: +${addedLines.length} lines, -${removedLines.length} lines');
        details['text_added'] = addedLines.take(10).toList();
        details['text_removed'] = removedLines.take(10).toList();
      }
    }
  } else {
    changes.add('New page (no baseline snapshot)');
  }

  details['current_snapshot'] = currentSnapshot;
  details['baseline_snapshot'] = baselineSnapshot;

  return {
    'page': safeName,
    'url': pageUrl,
    'status': changes.isEmpty ? 'unchanged' : 'changed',
    'changes': changes,
    'details': details,
  };
}

/// Simple pixel diff - compares raw bytes and returns percentage difference
double _pixelDiff(List<int> a, List<int> b) {
  if (a.isEmpty || b.isEmpty) return 100.0;
  // Compare file sizes as a rough proxy (real pixel diff would decode PNG)
  final sizeDiff = (a.length - b.length).abs();
  final maxSize = a.length > b.length ? a.length : b.length;
  if (maxSize == 0) return 0.0;

  // Compare byte-by-byte up to the shorter length
  final minLen = a.length < b.length ? a.length : b.length;
  int diffCount = 0;
  for (var i = 0; i < minLen; i++) {
    if (a[i] != b[i]) diffCount++;
  }
  diffCount += sizeDiff;
  return (diffCount / maxSize) * 100;
}

/// Generate safe filename from URL
String _safeFileName(String url) {
  return url
      .replaceAll(RegExp(r'https?://'), '')
      .replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^_|_$'), '');
}

/// Generate HTML diff report
Future<void> _generateDiffReport(
  List<Map<String, dynamic>> results,
  String reportPath,
  String baselinePath,
) async {
  final buf = StringBuffer();
  buf.writeln('<!DOCTYPE html>');
  buf.writeln('<html><head><meta charset="utf-8">');
  buf.writeln('<title>Diff Report — flutter-skill</title>');
  buf.writeln('<style>');
  buf.writeln('''
    body { font-family: -apple-system, sans-serif; margin: 0; padding: 20px; background: #f5f5f5; }
    .header { background: #1a1a2e; color: white; padding: 20px; border-radius: 8px; margin-bottom: 20px; }
    .summary { display: flex; gap: 20px; margin-bottom: 20px; }
    .stat { background: white; padding: 15px 20px; border-radius: 8px; flex: 1; text-align: center; }
    .stat .number { font-size: 2em; font-weight: bold; }
    .stat.pass .number { color: #22c55e; }
    .stat.fail .number { color: #ef4444; }
    .stat.warn .number { color: #f59e0b; }
    .page { background: white; border-radius: 8px; padding: 20px; margin-bottom: 16px; }
    .page.changed { border-left: 4px solid #ef4444; }
    .page.unchanged { border-left: 4px solid #22c55e; }
    .page.removed { border-left: 4px solid #6b7280; opacity: 0.7; }
    .screenshots { display: flex; gap: 10px; margin-top: 10px; }
    .screenshots img { max-width: 48%; border: 1px solid #ddd; border-radius: 4px; }
    .changes { margin-top: 10px; }
    .change { padding: 4px 8px; background: #fef2f2; border-radius: 4px; margin: 4px 0; font-size: 0.9em; }
    .text-diff { margin-top: 10px; font-family: monospace; font-size: 0.85em; }
    .added { color: #22c55e; background: #f0fdf4; padding: 2px 4px; }
    .removed { color: #ef4444; background: #fef2f2; padding: 2px 4px; text-decoration: line-through; }
    h2 { margin: 0 0 5px 0; }
    .url { color: #6b7280; font-size: 0.9em; }
    .badge { display: inline-block; padding: 2px 8px; border-radius: 12px; font-size: 0.8em; font-weight: bold; }
    .badge.changed { background: #fef2f2; color: #ef4444; }
    .badge.unchanged { background: #f0fdf4; color: #22c55e; }
    .badge.removed { background: #f3f4f6; color: #6b7280; }
  ''');
  buf.writeln('</style></head><body>');

  // Header
  buf.writeln('<div class="header">');
  buf.writeln('<h1>🔍 Diff Report</h1>');
  buf.writeln(
      '<p>Generated by flutter-skill • ${DateTime.now().toIso8601String()}</p>');
  buf.writeln('</div>');

  // Summary
  final total = results.length;
  final unchanged = results.where((r) => r['status'] == 'unchanged').length;
  final changed = results.where((r) => r['status'] == 'changed').length;
  final removed = results.where((r) => r['status'] == 'removed').length;

  buf.writeln('<div class="summary">');
  buf.writeln(
      '<div class="stat"><div class="number">$total</div><div>Total Pages</div></div>');
  buf.writeln(
      '<div class="stat pass"><div class="number">$unchanged</div><div>Unchanged</div></div>');
  buf.writeln(
      '<div class="stat fail"><div class="number">$changed</div><div>Changed</div></div>');
  if (removed > 0) {
    buf.writeln(
        '<div class="stat warn"><div class="number">$removed</div><div>Removed</div></div>');
  }
  buf.writeln('</div>');

  // Pages
  for (final result in results) {
    final status = result['status'] as String;
    final pageUrl = result['url'] as String;
    final changes = result['changes'] as List? ?? [];
    final details = result['details'] as Map<String, dynamic>? ?? {};

    buf.writeln('<div class="page $status">');
    buf.writeln(
        '<h2>${result['page']} <span class="badge $status">$status</span></h2>');
    buf.writeln('<div class="url">$pageUrl</div>');

    if (changes.isNotEmpty) {
      buf.writeln('<div class="changes">');
      for (final change in changes) {
        buf.writeln('<div class="change">$change</div>');
      }
      buf.writeln('</div>');
    }

    // Screenshots side by side
    if (details['baseline_screenshot'] != null &&
        details['current_screenshot'] != null) {
      try {
        final baselineFile = File(details['baseline_screenshot'] as String);
        final currentFile = File(details['current_screenshot'] as String);
        if (baselineFile.existsSync() && currentFile.existsSync()) {
          final baseB64 = base64.encode(await baselineFile.readAsBytes());
          final currB64 = base64.encode(await currentFile.readAsBytes());
          buf.writeln('<div class="screenshots">');
          buf.writeln('<div><strong>Baseline</strong><br>');
          buf.writeln('<img src="data:image/png;base64,$baseB64"></div>');
          buf.writeln('<div><strong>Current</strong><br>');
          buf.writeln('<img src="data:image/png;base64,$currB64"></div>');
          buf.writeln('</div>');
        }
      } catch (_) {}
    }

    // Text diff
    final textAdded = details['text_added'] as List?;
    final textRemoved = details['text_removed'] as List?;
    if (textAdded != null || textRemoved != null) {
      buf.writeln('<div class="text-diff">');
      if (textRemoved != null) {
        for (final line in textRemoved) {
          buf.writeln(
              '<div class="removed">- ${_escapeHtml(line.toString())}</div>');
        }
      }
      if (textAdded != null) {
        for (final line in textAdded) {
          buf.writeln(
              '<div class="added">+ ${_escapeHtml(line.toString())}</div>');
        }
      }
      buf.writeln('</div>');
    }

    buf.writeln('</div>');
  }

  buf.writeln('</body></html>');

  final file = File(reportPath);
  await file.writeAsString(buf.toString());
}

String _escapeHtml(String text) {
  return text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');
}
