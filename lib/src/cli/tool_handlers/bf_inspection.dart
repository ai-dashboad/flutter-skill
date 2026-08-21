part of '../server.dart';

extension _BfInspection on FlutterMcpServer {
  Future<dynamic> _handleInspectionTool(
      String name, Map<String, dynamic> args, AppDriver? client) async {
    switch (name) {
      case 'inspect':
        final elements = await client!.getInteractiveElements();
        final currentPageOnly = args['current_page_only'] ?? true;
        if (currentPageOnly) {
          final filtered = elements.where((e) {
            if (e is! Map) return true;
            final bounds = e['bounds'];
            if (bounds == null) return true;
            final x = bounds['x'] as int? ?? 0;
            final y = bounds['y'] as int? ?? 0;
            final visible = e['visible'] ?? true;
            // Exclude elements with negative coordinates (off-screen / background pages)
            return visible == true && x >= -10 && y >= -10;
          }).toList();
          return filtered;
        }
        return elements;
      case 'inspect_interactive':
        if (client is BridgeDriver) {
          return await client.getInteractiveElementsStructured();
        }
        final fc = _asFlutterClient(client!, 'inspect_interactive');
        return await fc.getInteractiveElementsStructured();
      case 'snapshot':
        final snapshotMode = args['mode'] as String? ?? 'text';
        if (snapshotMode == 'vision') {
          final imageBase64 =
              await client!.takeScreenshot(quality: 0.5, maxWidth: 800);
          if (imageBase64 == null)
            return {"success": false, "error": "Failed to capture screenshot"};
          final tempDir = Directory.systemTemp;
          final timestamp = DateTime.now().millisecondsSinceEpoch;
          final file =
              File('${tempDir.path}/flutter_skill_vision_$timestamp.png');
          await file.writeAsBytes(base64.decode(imageBase64));
          return {"mode": "vision", "path": file.path, "success": true};
        }
        final structured = await client!.getInteractiveElementsStructured();
        final snapshotElements = structured['elements'] as List<dynamic>? ?? [];

        // Also get all elements (including non-interactive) for richer snapshot
        List<dynamic> allElements = [];
        try {
          allElements = await client.getInteractiveElements();
        } catch (_) {
          // Fall back to interactive-only if full inspect fails
        }

        // Build text-based accessibility tree
        final buffer = StringBuffer();

        // Build interactive ref set for quick lookup
        final refSet = <String>{};
        for (final el in snapshotElements) {
          if (el is Map && el['ref'] != null) {
            refSet.add(el['ref'].toString());
          }
        }

        // Merge: interactive elements have refs, non-interactive are context
        final allMerged = <Map<String, dynamic>>[];

        // Add interactive elements with full data
        for (final el in snapshotElements) {
          if (el is Map<String, dynamic>) {
            allMerged.add({...el, '_interactive': true});
          }
        }

        // Add non-interactive elements from inspect (text, images, etc.)
        for (final el in allElements) {
          if (el is Map<String, dynamic>) {
            final isInteractive = el['clickable'] == true ||
                el['type']?.toString().contains('Button') == true ||
                el['type']?.toString().contains('TextField') == true ||
                el['type']?.toString().contains('Input') == true;
            if (!isInteractive) {
              allMerged.add({...el, '_interactive': false});
            }
          }
        }

        // Sort by position (top to bottom, left to right)
        allMerged.sort((a, b) {
          final aB = a['bounds'] as Map<String, dynamic>?;
          final bB = b['bounds'] as Map<String, dynamic>?;
          final ay = (aB?['y'] ?? 0) as num;
          final by = (bB?['y'] ?? 0) as num;
          if (ay != by) return ay.compareTo(by);
          final ax = (aB?['x'] ?? 0) as num;
          final bx = (bB?['x'] ?? 0) as num;
          return ax.compareTo(bx);
        });

        // Format as tree
        for (var i = 0; i < allMerged.length; i++) {
          final el = allMerged[i];
          final isLast = i == allMerged.length - 1;
          final prefix = isLast ? '└── ' : '├── ';
          final bounds = el['bounds'] as Map<String, dynamic>?;
          final bStr = bounds != null
              ? '(${bounds['x']},${bounds['y']} ${bounds['w']}x${bounds['h']})'
              : '';

          if (el['_interactive'] == true) {
            // Interactive element with ref
            final ref = el['ref'] ?? '';
            final text = el['text']?.toString() ?? '';
            final label = el['label']?.toString() ?? '';
            final value = el['value']?.toString();
            final enabled = el['enabled'] != false;
            final actions = (el['actions'] as List?)?.join(',') ?? '';

            String displayText = text.isNotEmpty ? text : label;
            if (displayText.length > 40)
              displayText = '${displayText.substring(0, 37)}...';

            final valuePart =
                value != null && value.isNotEmpty ? ' value="$value"' : '';
            final enabledPart = enabled ? '' : ' DISABLED';

            buffer.writeln(
                '$prefix[$ref] "$displayText" $bStr$valuePart$enabledPart {$actions}');
          } else {
            // Non-interactive element (context)
            final type = el['type']?.toString() ?? 'unknown';
            final text = el['text']?.toString() ?? '';
            final shortType = type
                .replaceAll('RenderObjectToWidgetAdapter<RenderBox>', 'Root')
                .split('.')
                .last;

            if (text.isNotEmpty) {
              String displayText = text;
              if (displayText.length > 50)
                displayText = '${displayText.substring(0, 47)}...';
              buffer.writeln('$prefix[$shortType] "$displayText" $bStr');
            }
            // Skip non-text non-interactive elements to keep snapshot compact
          }
        }

        final snapshotText = buffer.toString();
        final summary = structured['summary'] ?? '';

        final result = <String, dynamic>{
          'snapshot': snapshotText,
          'summary': summary,
          'elementCount': allMerged.length,
          'interactiveCount': snapshotElements.length,
          'tokenEstimate': snapshotText.length ~/ 4,
          'hint':
              'Use ref IDs to interact: tap(ref: "button:Login"), enter_text(ref: "input:Email", text: "...")',
        };
        if (snapshotMode == 'smart') {
          final hasVisual = allMerged.any((el) {
            final type = (el['type'] ?? '').toString().toLowerCase();
            return type.contains('image') ||
                type.contains('video') ||
                type.contains('picture') ||
                type.contains('icon');
          });
          if (hasVisual) {
            result['has_visual_content'] = true;
            result['hint'] =
                'Use screenshot() if you need to verify images/visual layout. ' +
                    (result['hint'] as String);
          }
        }
        return result;
      case 'get_widget_tree':
        if (client is BridgeDriver) {
          // Non-Flutter bridges: delegate to inspect (component/accessibility tree)
          final result = await client.callMethod('inspect', {});
          result['source'] = 'bridge_inspect';
          result['framework'] = client.frameworkName;
          result['hint'] =
              'This is the component/accessibility tree from the ${client.frameworkName} bridge SDK. '
              'For Flutter apps, get_widget_tree returns the full widget tree via VM Service.';
          return result;
        }
        final fc = _asFlutterClient(client!, 'get_widget_tree');
        final maxDepth = args['max_depth'] ?? 10;
        return await fc.getWidgetTree(maxDepth: maxDepth);
      case 'get_widget_properties':
        if (client is BridgeDriver) {
          return await client.callMethod('get_widget_properties', {
            'key': args['key'] as String?,
            'element': args['element'] as String?,
          });
        }
        final fc = _asFlutterClient(client!, 'get_widget_properties');
        final wpKey = (args['key'] ?? args['element'] ?? '') as String;
        if (wpKey.isEmpty) {
          return {
            "success": false,
            "error": "key or element parameter required"
          };
        }
        final props = await fc.getWidgetProperties(wpKey);
        return props ??
            {
              "success": false,
              "error": "No mounted widget with key '$wpKey' "
                  "(is it on the current screen / built?)",
            };
      case 'get_text_content':
        if (client is BridgeDriver) {
          final text = await client.getText();
          return {"success": true, "text": text};
        }
        final fc = _asFlutterClient(client!, 'get_text_content');
        return await fc.getTextContent();
      case 'find_by_type':
        final fc = _asFlutterClient(client!, 'find_by_type');
        return await fc.findByType(args['type']);

      case 'accessibility_audit':
        if (client is BridgeDriver) {
          // Bridge platform: use SDK's inspect_interactive to build a11y report
          final structured = await client.getInteractiveElementsStructured();
          final elements = (structured['elements'] as List<dynamic>?) ?? [];
          final issues = <Map<String, dynamic>>[];

          for (final el in elements) {
            if (el is! Map<String, dynamic>) continue;
            final type = (el['type'] as String? ?? '').toLowerCase();
            final text = (el['text'] as String? ?? '').trim();
            final label = (el['label'] as String? ?? '').trim();
            final ref = el['ref'] as String? ?? '';

            // Check buttons without accessible name
            if ((type == 'button' || ref.startsWith('button:')) &&
                text.isEmpty &&
                label.isEmpty) {
              issues.add({
                'type': 'error',
                'rule': 'button-name',
                'message': 'Button has no accessible name',
                'element': ref,
              });
            }

            // Check inputs without label/hint
            if ((type == 'input' ||
                    type == 'textarea' ||
                    ref.startsWith('input:')) &&
                label.isEmpty) {
              issues.add({
                'type': 'warning',
                'rule': 'input-label',
                'message': 'Input missing label or hint text',
                'element': ref,
              });
            }
          }

          return {
            'issues': issues,
            'total': issues.length,
            'errors': issues.where((i) => i['type'] == 'error').length,
            'warnings': issues.where((i) => i['type'] == 'warning').length,
            'platform': 'bridge',
          };
        }
        // Non-bridge, non-CDP — not supported
        return {
          'issues': [],
          'total': 0,
          'error': 'accessibility_audit requires CDP or Bridge connection',
        };

      // Basic Actions
      default:
        return null;
    }
  }
}
