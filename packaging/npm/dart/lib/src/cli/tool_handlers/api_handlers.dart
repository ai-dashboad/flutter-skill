part of '../server.dart';

extension _ApiHandlers on FlutterMcpServer {
  /// Handle API testing tools.
  /// Returns null if the tool is not handled by this group.
  Future<dynamic> _handleApiTools(
      String name, Map<String, dynamic> args) async {
    if (name == 'api_request') {
      return _handleApiRequest(args);
    }
    if (name == 'api_assert') {
      return _handleApiAssert(args);
    }
    if (name == 'download_file') {
      return _handleDownloadFile(args);
    }
    return null;
  }

  Future<Map<String, dynamic>> _handleApiRequest(
      Map<String, dynamic> args) async {
    final urlStr = args['url'] as String?;
    if (urlStr == null) {
      return {'success': false, 'error': 'url is required'};
    }

    final method = (args['method'] as String?)?.toUpperCase() ?? 'GET';
    final headers = (args['headers'] as Map<String, dynamic>?) ?? {};
    final body = args['body'] as String?;
    final expectStatus = args['expect_status'] as int?;
    final expectBodyContains = args['expect_body_contains'] as String?;
    final expectJsonPath = args['expect_json_path'] as String?;
    final expectJsonValue = args['expect_json_value'];

    final client = HttpClient();
    try {
      final uri = Uri.parse(urlStr);
      final request = await _createRequest(client, method, uri);

      // Set headers
      for (final entry in headers.entries) {
        request.headers.set(entry.key, entry.value.toString());
      }

      // Set body
      if (body != null) {
        request.headers.contentType =
            ContentType('application', 'json', charset: 'utf-8');
        request.write(body);
      }

      final response = await request.close();
      final responseBody = await response.transform(utf8.decoder).join();
      final statusCode = response.statusCode;

      // Build response headers map
      final responseHeaders = <String, String>{};
      response.headers.forEach((name, values) {
        responseHeaders[name] = values.join(', ');
      });

      // Validate expectations
      final assertions = <Map<String, dynamic>>[];
      var allPassed = true;

      if (expectStatus != null) {
        final passed = statusCode == expectStatus;
        if (!passed) allPassed = false;
        assertions.add({
          'type': 'status_code',
          'expected': expectStatus,
          'actual': statusCode,
          'passed': passed,
        });
      }

      if (expectBodyContains != null) {
        final passed = responseBody.contains(expectBodyContains);
        if (!passed) allPassed = false;
        assertions.add({
          'type': 'body_contains',
          'expected': expectBodyContains,
          'passed': passed,
        });
      }

      if (expectJsonPath != null) {
        try {
          final json = jsonDecode(responseBody);
          final actual = _resolveJsonPath(json, expectJsonPath);
          if (expectJsonValue != null) {
            final passed = actual.toString() == expectJsonValue.toString();
            if (!passed) allPassed = false;
            assertions.add({
              'type': 'json_path',
              'path': expectJsonPath,
              'expected': expectJsonValue,
              'actual': actual,
              'passed': passed,
            });
          } else {
            assertions.add({
              'type': 'json_path',
              'path': expectJsonPath,
              'actual': actual,
              'passed': actual != null,
            });
            if (actual == null) allPassed = false;
          }
        } catch (e) {
          allPassed = false;
          assertions.add({
            'type': 'json_path',
            'path': expectJsonPath,
            'error': 'Failed to parse JSON: $e',
            'passed': false,
          });
        }
      }

      return {
        'success': allPassed,
        'status_code': statusCode,
        'body': responseBody.length > 4096
            ? responseBody.substring(0, 4096)
            : responseBody,
        'body_length': responseBody.length,
        'headers': responseHeaders,
        if (assertions.isNotEmpty) 'assertions': assertions,
      };
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    } finally {
      client.close();
    }
  }

  Future<Map<String, dynamic>> _handleApiAssert(
      Map<String, dynamic> args) async {
    final urlStr = args['url'] as String?;
    final jsonPath = args['json_path'] as String?;
    if (urlStr == null || jsonPath == null) {
      return {'success': false, 'error': 'url and json_path are required'};
    }

    final method = (args['method'] as String?)?.toUpperCase() ?? 'GET';
    final headers = (args['headers'] as Map<String, dynamic>?) ?? {};
    final expectedValue = args['expected_value'];
    final comparison = args['comparison'] as String? ?? 'equals';

    final client = HttpClient();
    try {
      final uri = Uri.parse(urlStr);
      final request = await _createRequest(client, method, uri);
      for (final entry in headers.entries) {
        request.headers.set(entry.key, entry.value.toString());
      }

      final response = await request.close();
      final responseBody = await response.transform(utf8.decoder).join();

      dynamic json;
      try {
        json = jsonDecode(responseBody);
      } catch (e) {
        return {
          'success': false,
          'error': 'Response is not valid JSON: $e',
          'status_code': response.statusCode,
        };
      }

      final actual = _resolveJsonPath(json, jsonPath);

      bool passed;
      switch (comparison) {
        case 'equals':
          passed = actual.toString() == expectedValue.toString();
          break;
        case 'contains':
          passed = actual.toString().contains(expectedValue.toString());
          break;
        case 'gt':
          passed = (actual is num) &&
              (expectedValue is num) &&
              actual > expectedValue;
          break;
        case 'lt':
          passed = (actual is num) &&
              (expectedValue is num) &&
              actual < expectedValue;
          break;
        case 'exists':
          passed = actual != null;
          break;
        case 'not_exists':
          passed = actual == null;
          break;
        default:
          passed = actual.toString() == expectedValue.toString();
      }

      return {
        'success': passed,
        'json_path': jsonPath,
        'actual': actual,
        'expected': expectedValue,
        'comparison': comparison,
        'status_code': response.statusCode,
      };
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    } finally {
      client.close();
    }
  }

  /// Create an HttpClientRequest for the given method
  Future<HttpClientRequest> _createRequest(
      HttpClient client, String method, Uri uri) {
    switch (method) {
      case 'POST':
        return client.postUrl(uri);
      case 'PUT':
        return client.putUrl(uri);
      case 'DELETE':
        return client.deleteUrl(uri);
      case 'PATCH':
        return client.patchUrl(uri);
      case 'GET':
      default:
        return client.getUrl(uri);
    }
  }

  Future<Map<String, dynamic>> _handleDownloadFile(
      Map<String, dynamic> args) async {
    final urlStr = args['url'] as String?;
    final savePath = args['save_path'] as String?;

    if (urlStr == null || savePath == null) {
      return {'success': false, 'error': 'url and save_path are required'};
    }

    try {
      final uri = Uri.parse(urlStr);
      final client = HttpClient();

      final request = await client.getUrl(uri);
      final response = await request.close();

      if (response.statusCode != 200) {
        client.close();
        return {
          'success': false,
          'error':
              'HTTP ${response.statusCode}: Failed to download from $urlStr'
        };
      }

      final file = File(savePath);
      // Create parent directories if they don't exist
      await file.parent.create(recursive: true);

      final sink = file.openWrite();
      await sink.addStream(response);
      await sink.close();
      client.close();

      final fileSize = await file.length();
      return {
        'success': true,
        'file_path': savePath,
        'size_bytes': fileSize,
        'url': urlStr,
        'status_code': response.statusCode,
      };
    } catch (e) {
      return {'success': false, 'error': 'Download failed: $e'};
    }
  }

  /// Resolve a simple JSONPath expression like `$.data.user.name`
  /// Supports dot-separated paths and array indexing like `$.items[0].name`
  dynamic _resolveJsonPath(dynamic json, String path) {
    // Strip leading $. or $
    var cleanPath = path;
    if (cleanPath.startsWith(r'$.')) {
      cleanPath = cleanPath.substring(2);
    } else if (cleanPath.startsWith(r'$')) {
      cleanPath = cleanPath.substring(1);
    }

    if (cleanPath.isEmpty) return json;

    dynamic current = json;
    // Split by dots, but handle array indices like items[0]
    final segments = cleanPath.split('.');

    for (final segment in segments) {
      if (current == null) return null;

      // Check for array index: e.g. "items[0]"
      final bracketMatch = RegExp(r'^(\w+)\[(\d+)\]$').firstMatch(segment);
      if (bracketMatch != null) {
        final key = bracketMatch.group(1)!;
        final index = int.parse(bracketMatch.group(2)!);
        if (current is Map) {
          current = current[key];
        } else {
          return null;
        }
        if (current is List && index < current.length) {
          current = current[index];
        } else {
          return null;
        }
      } else {
        // Simple key access
        if (current is Map) {
          current = current[segment];
        } else {
          return null;
        }
      }
    }

    return current;
  }
}
