part of '../server.dart';

extension _ParallelHandlers on FlutterMcpServer {
  /// Parallel and multi-platform testing tools
  /// Returns null if the tool is not handled.
  Future<dynamic> _handleParallelTools(
      String name, Map<String, dynamic> args) async {
    if (name == 'parallel_snapshot') {
      final sessionIds =
          (args['session_ids'] as List<dynamic>?)?.cast<String>() ??
              _sessions.keys.toList();
      final futures = sessionIds.map((sid) async {
        try {
          final c = _clients[sid];
          if (c == null) return {"session_id": sid, "error": "Not connected"};
          if (c is FlutterSkillClient) {
            final structured = await c.getInteractiveElementsStructured();
            return {
              "session_id": sid,
              "snapshot": structured,
              "platform": _sessions[sid]?.deviceId
            };
          }
          return {"session_id": sid, "error": "Not a Flutter client"};
        } catch (e) {
          return {"session_id": sid, "error": e.toString()};
        }
      });
      final results = await Future.wait(futures);
      return {"devices": results, "device_count": results.length};
    }

    if (name == 'parallel_tap') {
      final sessionIds =
          (args['session_ids'] as List<dynamic>?)?.cast<String>() ??
              _sessions.keys.toList();
      final ref = args['ref'] as String?;
      final key = args['key'] as String?;
      final text = args['text'] as String?;
      final futures = sessionIds.map((sid) async {
        try {
          final c = _clients[sid];
          if (c == null)
            return {
              "session_id": sid,
              "success": false,
              "error": "Not connected"
            };
          final result = await c.tap(key: key, text: text, ref: ref);
          return {
            "session_id": sid,
            "success": true,
            "platform": _sessions[sid]?.deviceId,
            "result": result
          };
        } catch (e) {
          return {"session_id": sid, "success": false, "error": e.toString()};
        }
      });
      final results = await Future.wait(futures);
      return {"results": results};
    }

    if (name == 'multi_platform_test') {
      final actions = (args['actions'] as List<dynamic>?) ?? [];
      final sessionIds =
          (args['session_ids'] as List<dynamic>?)?.cast<String>() ??
              _sessions.keys.toList();
      final stopOnFailure = args['stop_on_failure'] as bool? ?? false;
      final savedSessionId = _activeSessionId;

      final futures = sessionIds.map((sid) async {
        final platform = _sessions[sid]?.deviceId ?? 'unknown';
        final steps = <Map<String, dynamic>>[];
        int passed = 0;
        int failed = 0;
        bool stopped = false;

        for (final action in actions) {
          if (stopped) break;
          final toolName =
              (action as Map<String, dynamic>)['tool'] as String? ?? '';
          final toolArgs = Map<String, dynamic>.from(
            (action['args'] as Map<String, dynamic>?) ?? {},
          );
          toolArgs['session_id'] = sid;

          final sw = Stopwatch()..start();
          try {
            // Temporarily switch active session for tools that rely on it
            _activeSessionId = sid;
            final result = await _executeToolInner(toolName, toolArgs);
            sw.stop();
            final success = result is Map ? (result['error'] == null) : true;
            steps.add({
              'tool': toolName,
              'success': success,
              'time_ms': sw.elapsedMilliseconds
            });
            if (success) {
              passed++;
            } else {
              failed++;
              if (stopOnFailure) stopped = true;
            }
          } catch (e) {
            sw.stop();
            steps.add({
              'tool': toolName,
              'success': false,
              'time_ms': sw.elapsedMilliseconds,
              'error': e.toString()
            });
            failed++;
            if (stopOnFailure) stopped = true;
          }
        }

        return MapEntry(sid, {
          'platform': platform,
          'steps': steps,
          'passed': passed,
          'failed': failed,
        });
      });

      final entries = await Future.wait(futures);
      _activeSessionId = savedSessionId;

      final results = Map.fromEntries(entries);
      final allPassed =
          results.values.where((r) => (r['failed'] as int) == 0).length;
      final someFailed =
          results.values.where((r) => (r['failed'] as int) > 0).length;

      return {
        'platforms_tested': sessionIds.length,
        'results': results,
        'summary': {
          'total_platforms': sessionIds.length,
          'all_passed': allPassed,
          'some_failed': someFailed,
        },
      };
    }

    if (name == 'compare_platforms') {
      final sessionIds =
          (args['session_ids'] as List<dynamic>?)?.cast<String>() ??
              _sessions.keys.toList();

      // Take snapshots from all platforms in parallel
      final futures = sessionIds.map((sid) async {
        try {
          final c = _clients[sid];
          if (c == null)
            return MapEntry(sid, <String, dynamic>{'error': 'Not connected'});
          if (c is FlutterSkillClient) {
            final structured = await c.getInteractiveElementsStructured();
            final elements = (structured['elements'] is List)
                ? (structured['elements'] as List)
                : <dynamic>[];
            final elementKeys = <String>{};
            for (final el in elements) {
              if (el is Map) {
                final type = el['type'] as String? ?? '';
                final text =
                    el['text'] as String? ?? el['label'] as String? ?? '';
                elementKeys.add('$type:$text');
              }
            }
            return MapEntry(sid, <String, dynamic>{
              'platform': _sessions[sid]?.deviceId ?? 'unknown',
              'element_count': elements.length,
              'elements': elementKeys.toList(),
            });
          }
          return MapEntry(
              sid, <String, dynamic>{'error': 'Not a Flutter client'});
        } catch (e) {
          return MapEntry(sid, <String, dynamic>{'error': e.toString()});
        }
      });

      final entries = await Future.wait(futures);
      final platformData = Map.fromEntries(entries);

      // Find all unique element keys across platforms
      final allElements = <String>{};
      final platformElements = <String, Set<String>>{};
      for (final entry in platformData.entries) {
        if (entry.value.containsKey('elements')) {
          final elems =
              (entry.value['elements'] as List).cast<String>().toSet();
          platformElements[entry.key] = elems;
          allElements.addAll(elems);
        }
      }

      // Build presence matrix and find inconsistencies
      final inconsistencies = <Map<String, dynamic>>[];
      final presenceMatrix = <String, Map<String, bool>>{};
      for (final element in allElements) {
        final presence = <String, bool>{};
        for (final sid in platformElements.keys) {
          presence[sid] = platformElements[sid]!.contains(element);
        }
        presenceMatrix[element] = presence;
        // If not present on all platforms, it's an inconsistency
        if (presence.values.any((v) => !v)) {
          inconsistencies.add({
            'element': element,
            'present_on': presence.entries
                .where((e) => e.value)
                .map((e) => e.key)
                .toList(),
            'missing_on': presence.entries
                .where((e) => !e.value)
                .map((e) => e.key)
                .toList(),
          });
        }
      }

      return {
        'platforms': platformData,
        'total_unique_elements': allElements.length,
        'inconsistencies': inconsistencies,
        'consistent': inconsistencies.isEmpty,
      };
    }

    // Auth inject session

    return null; // Not handled by this group
  }
}
