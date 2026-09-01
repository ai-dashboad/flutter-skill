part of '../server.dart';

extension _BfScreenshot on FlutterMcpServer {
  /// Image vs logical geometry so an agent can convert pixels it sees in the
  /// PNG back to the logical coordinates that tap_at/swipe/drag expect.
  Map<String, dynamic> _screenshotGeometry(Map<String, dynamic> info) {
    final imageWidth = info['imageWidth'] as num?;
    final logicalWidth = info['logicalWidth'] as num?;
    if (imageWidth == null || logicalWidth == null || logicalWidth == 0) {
      return const {};
    }
    final scale = imageWidth / logicalWidth;
    return {
      "image_size": {"width": imageWidth, "height": info['imageHeight']},
      "logical_size": {"width": logicalWidth, "height": info['logicalHeight']},
      "device_pixel_ratio": info['devicePixelRatio'],
      "scale": scale,
      "coordinates_hint": "Tools take LOGICAL coordinates. To tap what you "
          "see at image pixel (px, py): x = px / scale, y = py / scale "
          "(scale = ${scale.toStringAsFixed(3)}). Prefer inspect() centers.",
    };
  }

  Future<dynamic> _handleScreenshotTool(
      String name, Map<String, dynamic> args, AppDriver? client) async {
    switch (name) {
      case 'screenshot':
        // Default to lower quality and max width to prevent token overflow
        final quality = (args['quality'] as num?)?.toDouble() ?? 0.8;
        final maxWidth = args['max_width'] as int? ?? 800;
        final saveToFile = args['save_to_file'] ??
            true; // Save to file by default to avoid token overflow

        Map<String, dynamic> geometry = const {};
        String? imageBase64;
        if (client is FlutterSkillClient) {
          final info = await client.takeScreenshotWithInfo(
              quality: quality, maxWidth: maxWidth);
          imageBase64 = info['image'] as String?;
          geometry = _screenshotGeometry(info);
        } else {
          imageBase64 = await client!
              .takeScreenshot(quality: quality, maxWidth: maxWidth);
        }

        // Fallback to native screenshot if bridge returns null
        // (e.g. React Native returns _needs_native flag)
        if (imageBase64 == null) {
          try {
            final nDriver = await _getNativeDriver(args);
            if (nDriver != null) {
              final nResult = await nDriver.screenshot(saveToFile: false);
              imageBase64 = nResult.base64Image;
            }
          } catch (_) {
            // Native fallback failed, continue to error
          }
        }

        if (imageBase64 == null) {
          return {
            "success": false,
            "error": "Failed to capture screenshot",
            "message":
                "Screenshot returned null. Try 'native_screenshot' tool instead."
          };
        }

        if (saveToFile) {
          // Save to temporary file
          final tempDir = Directory.systemTemp;
          final timestamp = DateTime.now().millisecondsSinceEpoch;
          final filename = 'flutter_skill_screenshot_$timestamp.png';
          final file = File('${tempDir.path}/$filename');

          // Decode base64 and write to file
          final bytes = base64.decode(imageBase64);
          await file.writeAsBytes(bytes);

          return {
            "success": true,
            "file_path": file.path,
            "filename": filename,
            "size_bytes": bytes.length,
            "quality": quality,
            "max_width": maxWidth,
            "format": "png",
            ...geometry,
            "message": "Screenshot saved to ${file.path}"
          };
        } else {
          // Return base64 (legacy behavior)
          return {
            "image": imageBase64,
            "quality": quality,
            "max_width": maxWidth,
            ...geometry,
            "warning":
                "Returning base64 data. Consider using save_to_file=true for large images."
          };
        }

      case 'screenshot_region':
        if (client is BridgeDriver) {
          final result = await client.callMethod('screenshot_region', {
            'x': (args['x'] as num).toDouble(),
            'y': (args['y'] as num).toDouble(),
            'width': (args['width'] as num).toDouble(),
            'height': (args['height'] as num).toDouble(),
          });
          return result;
        }
        final fc = _asFlutterClient(client!, 'screenshot_region');
        final x = (args['x'] as num).toDouble();
        final y = (args['y'] as num).toDouble();
        final width = (args['width'] as num).toDouble();
        final height = (args['height'] as num).toDouble();
        final saveToFile = args['save_to_file'] ?? true;
        final image = await fc.takeRegionScreenshot(x, y, width, height);

        if (image == null) {
          return {
            "success": false,
            "error": "Failed to capture region screenshot",
          };
        }

        if (saveToFile) {
          final tempDir = Directory.systemTemp;
          final timestamp = DateTime.now().millisecondsSinceEpoch;
          final filename = 'flutter_skill_region_$timestamp.png';
          final file = File('${tempDir.path}/$filename');
          final bytes = base64.decode(image);
          await file.writeAsBytes(bytes);
          return {
            "success": true,
            "file_path": file.path,
            "size_bytes": bytes.length,
            "region": {"x": x, "y": y, "width": width, "height": height},
            "message": "Region screenshot saved to ${file.path}"
          };
        }

        return {
          "success": true,
          "image": image,
          "region": {"x": x, "y": y, "width": width, "height": height},
          "warning":
              "Returning base64 data. Consider using save_to_file=true for large regions."
        };

      // AI Visual Verification
      case 'visual_verify':
        final verifyQuality = (args['quality'] as num?)?.toDouble() ?? 0.5;
        final verifyDesc = args['description'] as String? ?? '';
        final checkElements =
            (args['check_elements'] as List?)?.cast<String>() ?? [];

        // Take screenshot
        final verifyImageBase64 =
            await client!.takeScreenshot(quality: verifyQuality, maxWidth: 800);
        String? verifyScreenshotPath;
        if (verifyImageBase64 != null) {
          final tempDir = Directory.systemTemp;
          final timestamp = DateTime.now().millisecondsSinceEpoch;
          final file =
              File('${tempDir.path}/flutter_skill_verify_$timestamp.png');
          await file.writeAsBytes(base64.decode(verifyImageBase64));
          verifyScreenshotPath = file.path;
        }

        // Take snapshot (text tree)
        String verifySnapshotText = '';
        List<String> foundElements = [];
        List<String> missingElements = [];
        int verifyElementCount = 0;
        try {
          final structured = await client.getInteractiveElementsStructured();
          final snapshotElements =
              structured['elements'] as List<dynamic>? ?? [];
          verifyElementCount = snapshotElements.length;

          final buf = StringBuffer();
          for (var i = 0; i < snapshotElements.length; i++) {
            final el = snapshotElements[i] as Map<String, dynamic>;
            final ref = el['ref'] ?? '';
            final text = el['text']?.toString() ?? '';
            final label = el['label']?.toString() ?? '';
            final display = text.isNotEmpty ? text : label;
            buf.writeln('[$ref] "$display"');
          }
          verifySnapshotText = buf.toString();

          // Check elements
          if (checkElements.isNotEmpty) {
            final snapshotLower = verifySnapshotText.toLowerCase();
            for (final check in checkElements) {
              if (snapshotLower.contains(check.toLowerCase())) {
                foundElements.add(check);
              } else {
                missingElements.add(check);
              }
            }
          }
        } catch (e) {
          verifySnapshotText = 'Error getting snapshot: $e';
        }

        return {
          'success': true,
          'screenshot': verifyScreenshotPath,
          'snapshot': verifySnapshotText,
          'elements_found': foundElements,
          'elements_missing': missingElements,
          'element_count': verifyElementCount,
          'description_to_verify': verifyDesc,
          'hint':
              'Compare the screenshot and snapshot against the description. Report any discrepancies.',
        };

      case 'visual_diff':
        final diffQuality = (args['quality'] as num?)?.toDouble() ?? 0.5;
        final baselinePath = args['baseline_path'] as String;
        final diffDesc = args['description'] as String? ?? '';

        final baselineFile = File(baselinePath);
        if (!await baselineFile.exists()) {
          return {
            'success': false,
            'error': 'Baseline file not found at path: $baselinePath',
            'suggestion':
                'Create a baseline first by taking a screenshot and saving it to this path, or use a different baseline_path',
            'baseline_path': baselinePath
          };
        }

        final diffImageBase64 =
            await client!.takeScreenshot(quality: diffQuality, maxWidth: 800);
        String? currentScreenshotPath;
        if (diffImageBase64 != null) {
          final tempDir = Directory.systemTemp;
          final timestamp = DateTime.now().millisecondsSinceEpoch;
          final file =
              File('${tempDir.path}/flutter_skill_diff_$timestamp.png');
          await file.writeAsBytes(base64.decode(diffImageBase64));
          currentScreenshotPath = file.path;
        }

        String diffSnapshotText = '';
        try {
          final structured = await client.getInteractiveElementsStructured();
          final els = structured['elements'] as List<dynamic>? ?? [];
          final buf = StringBuffer();
          for (final el in els) {
            if (el is Map<String, dynamic>) {
              final ref = el['ref'] ?? '';
              final text = el['text']?.toString() ?? '';
              final label = el['label']?.toString() ?? '';
              buf.writeln('[$ref] "${text.isNotEmpty ? text : label}"');
            }
          }
          diffSnapshotText = buf.toString();
        } catch (e) {
          diffSnapshotText = 'Error: $e';
        }

        return {
          'success': true,
          'baseline_path': baselinePath,
          'current_screenshot': currentScreenshotPath,
          'current_snapshot': diffSnapshotText,
          'description': diffDesc,
          'hint':
              'Compare the baseline screenshot with the current screenshot. Look for visual differences. The text snapshot shows the current UI structure.',
        };

      case 'screenshot_element':
        // Support both key and text parameters
        String? targetKey = args['key'];

        // If text is provided, find the element first
        if (targetKey == null && args['text'] != null) {
          final elements = await client!.getInteractiveElements();
          final matchingElement = elements.firstWhere(
            (e) => e['text'] == args['text'],
            orElse: () => <String, dynamic>{},
          );
          targetKey = matchingElement['key'];
        }

        if (targetKey == null) {
          return {
            "error": "Element not found",
            "message":
                "No element found with key or text: ${args['key'] ?? args['text']}",
          };
        }

        if (client is BridgeDriver) {
          final result =
              await client.callMethod('screenshot_element', {'key': targetKey});
          return result;
        }
        final fc = _asFlutterClient(client!, 'screenshot_element');
        final image = await fc.takeElementScreenshot(targetKey);
        if (image == null) {
          return {
            "error": "Screenshot failed",
            "message": "Could not capture screenshot of element",
          };
        }
        return {"image": image};

      // Navigation
      default:
        return null;
    }
  }
}
