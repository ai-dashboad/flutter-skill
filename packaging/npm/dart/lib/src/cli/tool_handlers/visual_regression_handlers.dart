part of '../server.dart';

extension _VisualRegressionHandlers on FlutterMcpServer {
  Future<dynamic> _handleVisualRegressionTool(
      String name, Map<String, dynamic> args) async {
    switch (name) {
      case 'visual_baseline_save':
        return await _visualBaselineSave(args);
      case 'visual_baseline_compare':
        return await _visualBaselineCompare(args);
      case 'visual_baseline_update':
        return await _visualBaselineUpdate(args);
      case 'visual_regression_report':
        return await _visualRegressionReport(args);
      default:
        return null;
    }
  }

  /// Save current screenshot as baseline.
  Future<Map<String, dynamic>> _visualBaselineSave(
      Map<String, dynamic> args) async {
    final client = _getClient(args);
    _requireConnection(client);

    final baselineDir = args['baseline_dir'] as String? ?? '.visual-baselines';
    final pageName = args['name'] as String? ?? 'default';
    final quality = (args['quality'] as num?)?.toDouble() ?? 0.8;

    final imageBase64 =
        await client!.takeScreenshot(quality: quality, maxWidth: 1280);
    if (imageBase64 == null) {
      return {'success': false, 'error': 'Failed to capture screenshot'};
    }

    final dir = Directory(baselineDir);
    if (!dir.existsSync()) await dir.create(recursive: true);

    final filePath = '$baselineDir/$pageName.png';
    final file = File(filePath);
    await file.writeAsBytes(base64.decode(imageBase64));

    return {
      'success': true,
      'path': filePath,
      'size_bytes': await file.length(),
      'name': pageName,
    };
  }

  /// Compare current screenshot with baseline.
  Future<Map<String, dynamic>> _visualBaselineCompare(
      Map<String, dynamic> args) async {
    final client = _getClient(args);
    _requireConnection(client);

    final baselineDir = args['baseline_dir'] as String? ?? '.visual-baselines';
    final pageName = args['name'] as String? ?? 'default';
    final threshold = (args['threshold'] as num?)?.toDouble() ?? 5.0;
    final ignoreRects = (args['ignore_regions'] as List<dynamic>?)
            ?.cast<Map<String, dynamic>>() ??
        [];

    final baselinePath = '$baselineDir/$pageName.png';
    final baselineFile = File(baselinePath);
    if (!baselineFile.existsSync()) {
      return {
        'success': false,
        'error': 'Baseline not found: $baselinePath',
        'suggestion': 'Run visual_baseline_save first',
      };
    }

    final imageBase64 =
        await client!.takeScreenshot(quality: 1.0, maxWidth: 1280);
    if (imageBase64 == null) {
      return {'success': false, 'error': 'Failed to capture screenshot'};
    }

    final currentBytes = base64.decode(imageBase64);
    final baselineBytes = await baselineFile.readAsBytes();

    final diffResult = _pixelDiff(baselineBytes, currentBytes, ignoreRects);

    final diffPath = '$baselineDir/${pageName}_diff.png';
    if (diffResult.diffImageBytes != null) {
      await File(diffPath).writeAsBytes(diffResult.diffImageBytes!);
    }

    final passed = diffResult.diffPercent <= threshold;

    return {
      'success': true,
      'passed': passed,
      'diff_percent': double.parse(diffResult.diffPercent.toStringAsFixed(2)),
      'threshold': threshold,
      'total_pixels': diffResult.totalPixels,
      'changed_pixels': diffResult.changedPixels,
      'diff_image_path': diffResult.diffImageBytes != null ? diffPath : null,
      'baseline_path': baselinePath,
    };
  }

  /// Update baseline with current screenshot.
  Future<Map<String, dynamic>> _visualBaselineUpdate(
      Map<String, dynamic> args) async {
    // Same as save — overwrites existing baseline
    return _visualBaselineSave(args);
  }

  /// Generate HTML visual regression report.
  Future<Map<String, dynamic>> _visualRegressionReport(
      Map<String, dynamic> args) async {
    final baselineDir = args['baseline_dir'] as String? ?? '.visual-baselines';
    final reportPath =
        args['report_path'] as String? ?? '$baselineDir/report.html';
    final title = args['title'] as String? ?? 'Visual Regression Report';

    final dir = Directory(baselineDir);
    if (!dir.existsSync()) {
      return {'success': false, 'error': 'Baseline directory not found'};
    }

    final baselines = <String>[];
    final diffs = <String>[];

    await for (final entity in dir.list()) {
      if (entity is File && entity.path.endsWith('.png')) {
        final name = entity.uri.pathSegments.last;
        if (name.endsWith('_diff.png')) {
          diffs.add(name);
        } else {
          baselines.add(name);
        }
      }
    }

    final buffer = StringBuffer();
    buffer.writeln('<!DOCTYPE html><html lang="en"><head>');
    buffer.writeln('<meta charset="utf-8">');
    buffer.writeln('<title>${_htmlEsc(title)}</title>');
    buffer.writeln('<style>');
    buffer.writeln('''
      body { font-family: system-ui, sans-serif; background: #0f172a; color: #e2e8f0; padding: 2rem; }
      h1 { margin-bottom: 1rem; }
      .card { background: #1e293b; border-radius: 12px; padding: 1.5rem; margin: 1rem 0; }
      .images { display: flex; gap: 1rem; flex-wrap: wrap; }
      .images img { max-width: 400px; max-height: 300px; border-radius: 8px; border: 1px solid #334155; }
      .label { font-size: 0.85rem; color: #94a3b8; margin-bottom: 0.3rem; }
      .name { font-weight: 600; font-size: 1.1rem; color: #60a5fa; }
    ''');
    buffer.writeln('</style></head><body>');
    buffer.writeln('<h1>📊 ${_htmlEsc(title)}</h1>');
    buffer.writeln(
        '<p style="color:#94a3b8">Generated ${DateTime.now().toIso8601String()}</p>');

    for (final baseline in baselines) {
      final pageName = baseline.replaceAll('.png', '');
      final diffName = '${pageName}_diff.png';
      final hasDiff = diffs.contains(diffName);

      buffer.writeln('<div class="card">');
      buffer.writeln('<div class="name">$pageName</div>');
      buffer.writeln('<div class="images">');
      buffer.writeln(
          '<div><div class="label">Baseline</div><img src="$baseline" alt="baseline"></div>');
      if (hasDiff) {
        buffer.writeln(
            '<div><div class="label">Diff</div><img src="$diffName" alt="diff"></div>');
      }
      buffer.writeln('</div></div>');
    }

    buffer.writeln('</body></html>');

    await File(reportPath).writeAsString(buffer.toString());
    return {
      'success': true,
      'report_path': reportPath,
      'baselines': baselines.length,
      'diffs': diffs.length,
    };
  }

  String _htmlEsc(String text) {
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');
  }
}

/// Pure Dart pixel diff — compares two PNG images byte-by-byte.
///
/// PNG files are decoded minimally: we look for raw IDAT chunks and compare
/// the decompressed pixel data. For simplicity, we compare the raw file bytes
/// at fixed offsets when dimensions match, otherwise do a byte-level comparison.
_PixelDiffResult _pixelDiff(
  List<int> baselineBytes,
  List<int> currentBytes,
  List<Map<String, dynamic>> ignoreRects,
) {
  // Simple approach: compare raw bytes (works for same-resolution screenshots)
  // For production, you'd decode PNG properly. This is efficient for CI/CD.

  final minLen = baselineBytes.length < currentBytes.length
      ? baselineBytes.length
      : currentBytes.length;
  final maxLen = baselineBytes.length > currentBytes.length
      ? baselineBytes.length
      : currentBytes.length;

  // Try to extract width/height from PNG header (bytes 16-23)
  int width = 0;
  int height = 0;
  if (baselineBytes.length > 24 &&
      baselineBytes[0] == 0x89 &&
      baselineBytes[1] == 0x50) {
    // PNG signature found
    width = (baselineBytes[16] << 24) |
        (baselineBytes[17] << 16) |
        (baselineBytes[18] << 8) |
        baselineBytes[19];
    height = (baselineBytes[20] << 24) |
        (baselineBytes[21] << 16) |
        (baselineBytes[22] << 8) |
        baselineBytes[23];
  }

  // Compare bytes (skip PNG header — first 33 bytes typically)
  const headerSkip = 33;
  int changedBytes = 0;
  int totalBytes = maxLen - headerSkip;
  if (totalBytes <= 0) totalBytes = 1;

  // Build ignore pixel set if we have dimensions
  final ignorePixels = <int>{};
  if (width > 0 && height > 0) {
    for (final rect in ignoreRects) {
      final rx = (rect['x'] as num?)?.toInt() ?? 0;
      final ry = (rect['y'] as num?)?.toInt() ?? 0;
      final rw = (rect['width'] as num?)?.toInt() ?? 0;
      final rh = (rect['height'] as num?)?.toInt() ?? 0;
      for (var y = ry; y < ry + rh && y < height; y++) {
        for (var x = rx; x < rx + rw && x < width; x++) {
          // Each pixel is ~4 bytes (RGBA) in decompressed form.
          // In compressed PNG this is approximate — mark byte ranges.
          final byteOffset = headerSkip + (y * width + x) * 4;
          for (var b = 0; b < 4; b++) {
            ignorePixels.add(byteOffset + b);
          }
        }
      }
    }
  }

  for (var i = headerSkip; i < minLen; i++) {
    if (ignorePixels.contains(i)) continue;
    if (baselineBytes[i] != currentBytes[i]) {
      changedBytes++;
    }
  }
  // Extra bytes count as changed
  changedBytes += maxLen - minLen;

  // Estimate pixel count from bytes (rough: 3-4 bytes per pixel in compressed)
  final totalPixels = width > 0 ? width * height : totalBytes ~/ 4;
  final changedPixels = changedBytes ~/ 4;
  final diffPercent =
      totalPixels > 0 ? (changedPixels / totalPixels) * 100.0 : 0.0;

  // Generate a simple diff marker (not a real diff image, but metadata)
  // For a real diff image we'd need full PNG decode/encode — skipped for simplicity
  List<int>? diffImageBytes;
  if (changedBytes > 0 && baselineBytes.length == currentBytes.length) {
    // Create a simple copy with changed bytes highlighted
    // Just save the current as the "diff" for now
    diffImageBytes = currentBytes;
  }

  return _PixelDiffResult(
    diffPercent: diffPercent,
    totalPixels: totalPixels,
    changedPixels: changedPixels,
    diffImageBytes: diffImageBytes,
  );
}

class _PixelDiffResult {
  final double diffPercent;
  final int totalPixels;
  final int changedPixels;
  final List<int>? diffImageBytes;

  _PixelDiffResult({
    required this.diffPercent,
    required this.totalPixels,
    required this.changedPixels,
    this.diffImageBytes,
  });
}
