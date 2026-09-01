part of '../server.dart';

extension _CdpConnectionHandlers2 on FlutterMcpServer {
  /// CDP connection and project diagnostics
  /// Returns null if the tool is not handled.
  Future<dynamic> _handleCdpConnectionTools(
      String name, Map<String, dynamic> args) async {
    if (name == 'connect_cdp') {
      final url = args['url'] as String? ?? '';
      final port = args['port'] as int? ?? 9222;
      final launchChrome = args['launch_chrome'] ?? (url.isNotEmpty);
      final headless = args['headless'] ?? false;
      final chromePath = args['chrome_path'] as String?;
      final proxy = args['proxy'] as String?;
      final ignoreSsl = args['ignore_ssl'] ?? false;
      final maxTabs = args['max_tabs'] as int? ?? 20;

      // Disconnect existing CDP connection if any
      if (_cdpDriver != null) {
        await _cdpDriver!.disconnect();
        _cdpDriver = null;
      }

      try {
        final driver = CdpDriver(
          url: url,
          port: port,
          launchChrome: launchChrome,
          headless: headless,
          chromePath: chromePath,
          proxy: proxy,
          ignoreSsl: ignoreSsl,
          maxTabs: maxTabs,
        );
        await driver.connect();
        _cdpDriver = driver;

        // Also store as a session so tools that use _getClient can find it
        final sessionId = 'cdp_${DateTime.now().millisecondsSinceEpoch}';
        _clients[sessionId] = driver;
        _sessions[sessionId] = SessionInfo(
          id: sessionId,
          name: 'CDP: $url',
          projectPath: url,
          deviceId: 'chrome',
          port: port,
          vmServiceUri: 'cdp://127.0.0.1:$port',
        );
        _activeSessionId = sessionId;

        return {
          "success": true,
          "mode": "cdp",
          "url": url,
          "port": port,
          "session_id": sessionId,
          "message": "Connected to $url via CDP on port $port",
          "note": "If Chrome was already running without remote debugging, "
              "flutter-skill auto-launched a debug-enabled profile alongside it.",
        };
      } catch (e) {
        return {
          "success": false,
          "error": {
            "code": "E601",
            "message": "CDP connection failed: $e",
          },
          "suggestions": [
            "Ensure Chrome is installed",
            "Let flutter-skill auto-launch Chrome: connect_cdp(url: '$url')",
            "Or point to an existing Chrome with debugging already on: "
                "connect_cdp(url: '$url', launch_chrome: false)",
            "Manual launch: google-chrome --remote-debugging-port=$port "
                "--user-data-dir=/tmp/chrome-debug",
          ],
        };
      }
    }

    if (name == 'connect_openclaw_browser') {
      // Connect to OpenClaw's built-in Chrome (port 18800, no launch)
      final url = args['url'] as String? ?? '';
      if (_cdpDriver != null) {
        await _cdpDriver!.disconnect();
        _cdpDriver = null;
      }
      try {
        final driver = CdpDriver(
          url: url,
          port: 18800,
          launchChrome: false,
          headless: false,
        );
        await driver.connect();
        _cdpDriver = driver;
        final sessionId = 'openclaw_${DateTime.now().millisecondsSinceEpoch}';
        _clients[sessionId] = driver;
        _sessions[sessionId] = SessionInfo(
          id: sessionId,
          name: 'OpenClaw Chrome${url.isNotEmpty ? ": $url" : ""}',
          projectPath: url,
          deviceId: 'openclaw-chrome',
          port: 18800,
          vmServiceUri: 'cdp://127.0.0.1:18800',
        );
        _activeSessionId = sessionId;
        return {
          "success": true,
          "mode": "cdp",
          "port": 18800,
          "url": url.isEmpty ? "(current page)" : url,
          "session_id": sessionId,
          "message": "Connected to OpenClaw Chrome on port 18800",
        };
      } catch (e) {
        return {
          "success": false,
          "error": {
            "code": "E602",
            "message": "OpenClaw Chrome connection failed: $e"
          },
          "suggestions": [
            "Ensure OpenClaw is running (openclaw gateway)",
            "Check Chrome is alive: lsof -i :18800",
            "Restart OpenClaw if Chrome process is dead",
          ],
        };
      }
    }

    if (name == 'connect_webmcp') {
      final url = args['url'] as String? ?? '';
      final webmcpPort = args['webmcp_port'] as int?;
      final fallbackCdpPort = args['fallback_cdp_port'] as int? ?? 18800;

      if (_cdpDriver != null) {
        await _cdpDriver!.disconnect();
        _cdpDriver = null;
      }

      // Probe WebMCP endpoint: Chrome 146 exposes MCP on the CDP port via /mcp path
      // Try candidate ports in order: explicit, CDP port 18800, 9222
      final candidatePorts = [
        if (webmcpPort != null) webmcpPort,
        18800,
        9222,
      ].toSet().toList();

      String? webmcpEndpoint;
      int? detectedPort;
      for (final port in candidatePorts) {
        try {
          final client = HttpClient();
          client.connectionTimeout = const Duration(seconds: 2);
          final req = await client
              .getUrl(Uri.parse('http://127.0.0.1:$port/json/version'));
          final res = await req.close();
          if (res.statusCode == 200) {
            // Check for WebMCP capability in response headers or body
            final body = await res.transform(const Utf8Decoder()).join();
            final hasWebMcp = body.contains('webSocketDebuggerUrl') ||
                body.contains('"Browser"');
            if (hasWebMcp) {
              detectedPort = port;
              // Chrome 146 WebMCP endpoint is typically /mcp on the debugging port
              webmcpEndpoint = 'http://127.0.0.1:$port/mcp';
            }
            client.close();
            if (detectedPort != null) break;
          }
          client.close();
        } catch (_) {}
      }

      // Attempt CDP connection (WebMCP uses same underlying Chrome)
      try {
        final effectivePort = detectedPort ?? fallbackCdpPort;
        final driver = CdpDriver(
          url: url,
          port: effectivePort,
          launchChrome: false,
          headless: false,
        );
        await driver.connect();
        _cdpDriver = driver;
        final sessionId = 'webmcp_${DateTime.now().millisecondsSinceEpoch}';
        _clients[sessionId] = driver;
        _sessions[sessionId] = SessionInfo(
          id: sessionId,
          name: 'WebMCP: $url',
          projectPath: url,
          deviceId: 'chrome-webmcp',
          port: effectivePort,
          vmServiceUri: 'cdp://127.0.0.1:$effectivePort',
        );
        _activeSessionId = sessionId;
        return {
          "success": true,
          "mode": webmcpEndpoint != null ? "webmcp" : "cdp_fallback",
          "port": effectivePort,
          "webmcp_endpoint": webmcpEndpoint,
          "url": url,
          "session_id": sessionId,
          "message": webmcpEndpoint != null
              ? "Connected via Chrome WebMCP on port $effectivePort"
              : "WebMCP not detected — connected via CDP fallback on port $effectivePort",
          "chrome_146_setup": webmcpEndpoint == null
              ? "Enable: chrome://flags/#enable-webmcp-testing → Restart Chrome"
              : null,
        };
      } catch (e) {
        return {
          "success": false,
          "error": {
            "code": "E603",
            "message": "WebMCP/CDP connection failed: $e"
          },
          "suggestions": [
            "Ensure Chrome 146+ is running",
            "Enable chrome://flags/#enable-webmcp-testing and restart Chrome",
            "For OpenClaw: ensure openclaw gateway is running",
          ],
        };
      }
    }

    if (name == 'diagnose_project') {
      final projectPath = args['project_path'] ?? '.';
      final autoFix = args['auto_fix'] ?? true;

      final diagnosticResult = <String, dynamic>{
        "project_path": projectPath,
        "checks": <String, dynamic>{},
        "issues": <String>[],
        "fixes_applied": <String>[],
        "recommendations": <String>[],
      };

      // Check pubspec.yaml
      final pubspecFile = File('$projectPath/pubspec.yaml');
      if (pubspecFile.existsSync()) {
        final pubspecContent = pubspecFile.readAsStringSync();
        final hasDependency = pubspecContent.contains('flutter_skill:');

        diagnosticResult['checks']['pubspec_yaml'] = {
          "status": hasDependency ? "ok" : "missing_dependency",
          "message": hasDependency
              ? "flutter_skill dependency found"
              : "flutter_skill dependency missing",
        };

        if (!hasDependency) {
          diagnosticResult['issues']
              .add("Missing flutter_skill dependency in pubspec.yaml");
          if (autoFix) {
            try {
              await runSetup(projectPath);
              diagnosticResult['fixes_applied']
                  .add("Added flutter_skill dependency to pubspec.yaml");
            } catch (e) {
              diagnosticResult['fixes_applied']
                  .add("Failed to add dependency: $e");
            }
          } else {
            diagnosticResult['recommendations']
                .add("Run: flutter pub add flutter_skill");
          }
        }
      } else {
        diagnosticResult['checks']['pubspec_yaml'] = {
          "status": "not_found",
          "message": "pubspec.yaml not found - not a Flutter project?",
        };
        diagnosticResult['issues']
            .add("pubspec.yaml not found at $projectPath");
      }

      // Check lib/main.dart
      final mainFile = File('$projectPath/lib/main.dart');
      if (mainFile.existsSync()) {
        final mainContent = mainFile.readAsStringSync();
        final hasImport =
            mainContent.contains('package:flutter_skill/flutter_skill.dart');
        final hasInit =
            mainContent.contains('FlutterSkillBinding.ensureInitialized()');

        diagnosticResult['checks']['main_dart'] = {
          "has_import": hasImport,
          "has_initialization": hasInit,
          "status": (hasImport && hasInit) ? "ok" : "incomplete",
          "message": (hasImport && hasInit)
              ? "FlutterSkillBinding properly configured"
              : "FlutterSkillBinding not properly initialized",
        };

        if (!hasImport || !hasInit) {
          if (!hasImport)
            diagnosticResult['issues']
                .add("Missing flutter_skill import in lib/main.dart");
          if (!hasInit)
            diagnosticResult['issues'].add(
                "Missing FlutterSkillBinding initialization in lib/main.dart");

          if (autoFix) {
            try {
              await runSetup(projectPath);
              diagnosticResult['fixes_applied'].add(
                  "Added FlutterSkillBinding initialization to lib/main.dart");
            } catch (e) {
              diagnosticResult['fixes_applied']
                  .add("Failed to update main.dart: $e");
            }
          } else {
            diagnosticResult['recommendations'].add(
                "Add to main.dart: FlutterSkillBinding.ensureInitialized()");
          }
        }
      } else {
        diagnosticResult['checks']['main_dart'] = {
          "status": "not_found",
          "message": "lib/main.dart not found",
        };
        diagnosticResult['issues'].add("lib/main.dart not found");
      }

      // Check running Flutter processes
      try {
        final result = await Process.run('pgrep', ['-f', 'flutter']);
        final hasRunningFlutter =
            result.exitCode == 0 && result.stdout.toString().trim().isNotEmpty;

        diagnosticResult['checks']['running_processes'] = {
          "flutter_running": hasRunningFlutter,
          "message": hasRunningFlutter
              ? "Flutter process detected"
              : "No Flutter process running",
        };

        if (!hasRunningFlutter) {
          diagnosticResult['recommendations']
              .add("Start your Flutter app with: flutter_skill launch .");
        }
      } catch (e) {
        diagnosticResult['checks']['running_processes'] = {
          "error": "Could not check processes: $e",
        };
      }

      // Check port availability
      final portsToCheck = [50000, 50001, 50002];
      final portStatus = <String, dynamic>{};

      for (final port in portsToCheck) {
        try {
          final result = await Process.run('lsof', ['-i', ':$port']);
          final inUse = result.exitCode == 0;
          portStatus['port_$port'] = inUse ? "in_use" : "available";
        } catch (e) {
          portStatus['port_$port'] = "unknown";
        }
      }

      diagnosticResult['checks']['ports'] = portStatus;

      // Generate summary
      final issueCount = (diagnosticResult['issues'] as List).length;
      final fixCount = (diagnosticResult['fixes_applied'] as List).length;

      diagnosticResult['summary'] = {
        "status": issueCount == 0
            ? "healthy"
            : (fixCount > 0 ? "fixed" : "needs_attention"),
        "issues_found": issueCount,
        "fixes_applied": fixCount,
        "message": issueCount == 0
            ? "✅ Project is properly configured"
            : (fixCount > 0
                ? "🔧 Fixed $fixCount issue(s), please restart your app"
                : "⚠️ Found $issueCount issue(s), run with auto_fix:true to fix"),
      };

      return diagnosticResult;
    }

    return null; // Not handled by this group
  }
}
