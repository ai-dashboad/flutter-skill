part of '../server.dart';

extension _BfLogging on FlutterMcpServer {
  Future<dynamic> _handleLoggingTool(
      String name, Map<String, dynamic> args, AppDriver? client) async {
    switch (name) {
      case 'get_logs':
        final logs = await client!.getLogs();
        return {
          "logs": logs,
          "summary": {
            "total_count": logs.length,
            "message": "${logs.length} log entries"
          }
        };
      case 'get_errors':
        if (client is BridgeDriver) {
          return await client.callMethod('get_errors',
              {'limit': args['limit'] ?? 50, 'offset': args['offset'] ?? 0});
        }
        final fc = _asFlutterClient(client!, 'get_errors');
        final allErrors = await fc.getErrors();
        final limit = int.tryParse('${args['limit'] ?? ''}') ?? 50;
        final offset = int.tryParse('${args['offset'] ?? ''}') ?? 0;
        final pagedErrors = allErrors.skip(offset).take(limit).toList();
        return {
          "errors": pagedErrors,
          "summary": {
            "total_count": allErrors.length,
            "returned_count": pagedErrors.length,
            "offset": offset,
            "limit": limit,
            "has_more": offset + limit < allErrors.length,
            "has_errors": allErrors.isNotEmpty,
            "message": allErrors.isEmpty
                ? "No errors found"
                : "${allErrors.length} error(s) total, showing ${pagedErrors.length} (offset: $offset)"
          }
        };
      case 'clear_logs':
        await client!.clearLogs();
        return {"success": true, "message": "Logs cleared successfully"};
      case 'get_performance':
        if (client is BridgeDriver) {
          return await client.callMethod('get_performance');
        }
        final fc = _asFlutterClient(client!, 'get_performance');
        return await fc.getPerformance();

      // === HTTP / Network Monitoring ===
      case 'enable_network_monitoring':
        if (client is BridgeDriver) {
          return await client.callMethod(
              'enable_network_monitoring', {'enable': args['enable'] ?? true});
        }
        final fc = _asFlutterClient(client!, 'enable_network_monitoring');
        final enable = args['enable'] ?? true;
        final success = await fc.enableHttpTimelineLogging(enable: enable);
        return {
          "success": success,
          "enabled": enable,
          "message": success
              ? "HTTP monitoring ${enable ? 'enabled' : 'disabled'}"
              : "Failed to enable HTTP monitoring (VM Service extension not available)",
          "usage": enable
              ? "Now perform actions, then call get_network_requests() to see API calls"
              : null,
        };

      case 'get_network_requests':
        if (client is BridgeDriver) {
          return await client.callMethod(
              'get_network_requests', {'limit': args['limit'] ?? 20});
        }
        final fc = _asFlutterClient(client!, 'get_network_requests');
        final limit = int.tryParse('${args['limit'] ?? ''}') ?? 20;
        // Try VM Service HTTP profile first (captures all dart:io HTTP)
        final profile = await fc.getHttpProfile();
        if (profile.containsKey('requests') && !profile.containsKey('error')) {
          final allRequests = (profile['requests'] as List?) ?? [];
          // Take latest N requests, format for readability
          final recentRequests = allRequests.length > limit
              ? allRequests.sublist(allRequests.length - limit)
              : allRequests;

          final formatted = recentRequests.map((r) {
            if (r is Map) {
              return {
                'id': r['id'],
                'method': r['method'],
                'uri': r['uri'],
                'status_code': r['response']?['statusCode'],
                'start_time': r['startTime'] != null
                    ? DateTime.fromMicrosecondsSinceEpoch(r['startTime'])
                        .toIso8601String()
                    : null,
                'end_time': r['endTime'] != null
                    ? DateTime.fromMicrosecondsSinceEpoch(r['endTime'])
                        .toIso8601String()
                    : null,
                'duration_ms': (r['endTime'] != null && r['startTime'] != null)
                    ? ((r['endTime'] - r['startTime']) / 1000).round()
                    : null,
                'content_type':
                    r['response']?['headers']?['content-type']?.toString(),
              };
            }
            return r;
          }).toList();

          return {
            "success": true,
            "source": "vm_service_http_profile",
            "requests": formatted,
            "total": allRequests.length,
            "returned": formatted.length,
            "message":
                "${formatted.length} of ${allRequests.length} HTTP requests"
          };
        }

        // Fallback: try manually logged requests from the binding
        final manualRequests = await fc.getHttpRequests(limit: limit);
        return {
          "success": true,
          "source": "manual_log",
          ...manualRequests,
          "hint":
              "For automatic HTTP capture, call enable_network_monitoring() first"
        };

      case 'clear_network_requests':
        if (client is BridgeDriver) {
          return await client.callMethod('clear_network_requests');
        }
        final fc = _asFlutterClient(client!, 'clear_network_requests');
        await fc.clearHttpRequests();
        return {"success": true, "message": "Network request history cleared"};

      // === NEW: Batch Operations ===
      default:
        return null;
    }
  }
}
