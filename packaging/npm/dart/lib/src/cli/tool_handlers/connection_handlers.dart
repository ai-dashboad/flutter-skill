part of '../server.dart';

extension _ConnectionHandlers on FlutterMcpServer {
  /// Connection, session, and HTTP tools
  /// Returns null if the tool is not handled.
  Future<dynamic> _handleConnectionTools(
      String name, Map<String, dynamic> args) async {
    // Session management tools
    if (name == 'list_sessions') {
      return {
        "sessions": _sessions.values.map((s) => s.toJson()).toList(),
        "active_session_id": _activeSessionId,
        "count": _sessions.length,
      };
    }

    if (name == 'switch_session') {
      final sessionId = args['session_id'] as String?;
      if (sessionId == null) {
        return {
          "success": false,
          "error": {"code": "E401", "message": "session_id is required"},
        };
      }

      if (!_sessions.containsKey(sessionId)) {
        return {
          "success": false,
          "error": {
            "code": "E402",
            "message": "Session not found: $sessionId",
          },
          "available_sessions": _sessions.keys.toList(),
        };
      }

      _activeSessionId = sessionId;
      return {
        "success": true,
        "message": "Switched to session $sessionId",
        "session": _sessions[sessionId]!.toJson(),
      };
    }

    if (name == 'close_session') {
      final sessionId = args['session_id'] as String?;
      if (sessionId == null) {
        return {
          "success": false,
          "error": {"code": "E401", "message": "session_id is required"},
        };
      }

      if (!_sessions.containsKey(sessionId)) {
        return {
          "success": false,
          "error": {
            "code": "E402",
            "message": "Session not found: $sessionId",
          },
        };
      }

      // Disconnect and remove client
      final client = _clients[sessionId];
      if (client != null) {
        await client.disconnect();
        _clients.remove(sessionId);
      }

      // Remove session
      _sessions.remove(sessionId);

      // Update active session
      if (_activeSessionId == sessionId) {
        _activeSessionId =
            _sessions.keys.isNotEmpty ? _sessions.keys.first : null;
      }

      return {
        "success": true,
        "message": "Closed session $sessionId",
        "active_session_id": _activeSessionId,
        "remaining_sessions": _sessions.length,
      };
    }

    // Connection tools
    if (name == 'connect_app') {
      var uri = args['uri'] as String;

      // Auto-fix configuration if project_path is provided
      final projectPath = args['project_path'] as String?;
      if (projectPath != null) {
        try {
          await runSetup(projectPath, quiet: true);
        } catch (e) {
          // Continue even if setup fails
          print('Warning: Auto-setup failed: $e');
        }
      }

      // Normalize URI format
      uri = _normalizeVmServiceUri(uri);

      // Create a new session for this connection
      final sessionId = args['session_id'] as String? ?? _generateSessionId();

      // Clean up all stale (disconnected) sessions before connecting
      await _cleanupStaleSessions();

      // If session already exists, disconnect it first
      if (_clients.containsKey(sessionId)) {
        await _clients[sessionId]!.disconnect();
      }

      // Probe for bridge protocol first (C++, React Native, Electron, etc.).
      // Bridge apps expose /.flutter-skill over plain HTTP on the same port.
      // If detected, use BridgeDriver instead of the Dart VM Service client.
      final bridgeInfo = await _probeBridgeUri(uri);
      if (bridgeInfo != null) {
        try {
          final driver = BridgeDriver.fromInfo(bridgeInfo);
          await driver.connect();
          _clients[sessionId] = driver;
          _sessions[sessionId] = SessionInfo(
            id: sessionId,
            name: args['name'] as String? ??
                '${bridgeInfo.framework} app (bridge)',
            projectPath: args['project_path'] as String? ?? 'unknown',
            deviceId: bridgeInfo.platform,
            port: bridgeInfo.port,
            vmServiceUri: bridgeInfo.wsUri,
          );
          _activeSessionId = sessionId;
          _lastConnectionUri = bridgeInfo.wsUri;
          _lastConnectionPort = bridgeInfo.port;
          return {
            "success": true,
            "message": "Connected to ${bridgeInfo.framework} bridge at $uri",
            "uri": bridgeInfo.wsUri,
            "framework": bridgeInfo.framework,
            "session_id": sessionId,
            "active_session": true,
          };
        } catch (e) {
          // Fall through to VM Service attempt if bridge connect fails
        }
      }

      // Retry logic with exponential backoff
      const maxRetries = 3;
      Exception? lastError;

      for (var attempt = 1; attempt <= maxRetries; attempt++) {
        try {
          final client = FlutterSkillClient(uri);
          await client.connect();

          // Store client and session info
          _clients[sessionId] = client;
          _sessions[sessionId] = SessionInfo(
            id: sessionId,
            name:
                args['name'] as String? ?? 'Connection ${_sessions.length + 1}',
            projectPath: args['project_path'] as String? ?? 'unknown',
            deviceId: args['device_id'] as String? ?? 'unknown',
            port: int.tryParse(uri.split(':').last.split('/').first) ?? 0,
            vmServiceUri: uri,
          );

          // Always switch to the newly created session
          _activeSessionId = sessionId;

          // Store for auto-reconnect
          _lastConnectionUri = uri;
          _lastConnectionPort =
              int.tryParse(uri.split(':').last.split('/').first);

          return {
            "success": true,
            "message": "Connected to $uri",
            "uri": uri,
            "session_id": sessionId,
            "active_session": true,
            "attempts": attempt,
          };
        } catch (e) {
          lastError = e is Exception ? e : Exception(e.toString());
          _clients.remove(sessionId);

          // Detect DTD protocol confusion early — no point retrying
          if (_looksLikeDtdUri(e.toString())) {
            final vmServiceUri = uri.endsWith('/ws') ? uri : '$uri/ws';
            return {
              "success": false,
              "error": {
                "code": "E_DTD_PROTOCOL",
                "message": "❌ Detected DTD protocol (not VM Service protocol)\n\n"
                    "The URI you provided connects to the Dart Tooling Daemon,\n"
                    "not the VM Service. flutter-skill requires a VM Service URI.\n\n"
                    "Expected format: ws://host:port/token=/ws\n"
                    "Your URI:        $uri",
              },
              "uri": uri,
              "suggestions": [
                "Use the VM Service URI (ends with /ws), not the DTD URI",
                "Try: connect_app(uri: '$vmServiceUri')",
                "Or let flutter-skill find it: scan_and_connect()",
                "Or launch fresh: launch_app(project_path: '.')",
              ],
            };
          }

          if (attempt < maxRetries) {
            // Wait before retry (100ms, 200ms, 400ms)
            await Future.delayed(
                Duration(milliseconds: 100 * (1 << (attempt - 1))));
          }
        }
      }

      return {
        "success": false,
        "error": {
          "code": "E201",
          "message": "Failed to connect after $maxRetries attempts: $lastError",
        },
        "uri": uri,
        "suggestions": [
          "Verify the app is running with 'flutter run'",
          "Check if the VM Service URI is correct",
          "Try scan_and_connect() to auto-detect running apps",
        ],
      };
    }

    if (name == 'launch_app') {
      final projectPath = args['project_path'] ?? '.';
      final deviceId = args['device_id'];
      final dartDefines = args['dart_defines'] as List<dynamic>?;
      final extraArgs = args['extra_args'] as List<dynamic>?;
      final flavor = args['flavor'];
      final target = args['target'];

      // Generate session ID for this launch
      final sessionId = args['session_id'] as String? ?? _generateSessionId();

      // If this session already has a running app, kill it
      if (_clients.containsKey(sessionId)) {
        await _clients[sessionId]!.disconnect();
        _clients.remove(sessionId);
      }

      if (_flutterProcess != null) {
        _flutterProcess!.kill();
        _flutterProcess = null;
      }

      final processArgs = ['run'];
      if (deviceId != null) processArgs.addAll(['-d', deviceId]);
      if (flavor != null) processArgs.addAll(['--flavor', flavor]);
      if (target != null) processArgs.addAll(['-t', target]);

      // Add dart defines
      if (dartDefines != null) {
        for (final define in dartDefines) {
          processArgs.addAll(['--dart-define', define.toString()]);
        }
      }

      // Add extra arguments
      if (extraArgs != null) {
        for (final arg in extraArgs) {
          processArgs.add(arg.toString());
        }
      }

      // Ensure VM Service is reachable on a fixed port so URI parsing works
      // reliably across Flutter versions (especially 3.38+ DDS proxy mode).
      if (!processArgs.any((a) => a.contains('--vm-service-port'))) {
        processArgs.add('--vm-service-port=50000');
      }

      try {
        await runSetup(projectPath, quiet: true);
      } catch (e) {
        // Continue even if setup fails
      }

      final flutterCmd = Platform.isWindows ? 'flutter.bat' : 'flutter';
      _flutterProcess = await Process.start(flutterCmd, processArgs,
          workingDirectory: projectPath,
          runInShell: Platform.isWindows);

      final completer = Completer<String>();
      final errorLines = <String>[];
      String? dtdUri; // Store DTD URI as fallback

      // Capture stdout (includes Flutter output and errors)
      _flutterProcess!.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        // Priority 1: Look for VM Service URI (http://.../)
        // Matches all known Flutter output formats:
        //   Flutter <=3.37: "The Dart VM service is listening on http://..."
        //   Flutter 3.38+:  "A Dart VM Service on <device> is available at: http://..."
        //   Observatory:    "Observatory listening on http://..."
        final lineLower = line.toLowerCase();
        if (lineLower.contains('vm service') || lineLower.contains('observatory')) {
          final vmRegex = RegExp(r'http://[a-zA-Z0-9.:\-_/=#]+[/#]?');
          final match = vmRegex.firstMatch(line);
          if (match != null && !completer.isCompleted) {
            final uri = match.group(0)!;

            // Disconnect old client for this session if exists
            if (_clients.containsKey(sessionId)) {
              _clients[sessionId]!.disconnect();
            }

            // Create new client and session
            final client = FlutterSkillClient(uri);
            client.connect().then((_) {
              // Store client and session info
              _clients[sessionId] = client;
              _sessions[sessionId] = SessionInfo(
                id: sessionId,
                name:
                    args['name'] as String? ?? 'App on ${deviceId ?? 'device'}',
                projectPath: projectPath,
                deviceId: deviceId?.toString() ?? 'unknown',
                port: int.tryParse(uri.split(':').last.split('/').first) ?? 0,
                vmServiceUri: uri,
              );

              // Always switch to the newly launched session
              _activeSessionId = sessionId;

              completer.complete("Launched and connected to $uri");
            }).catchError((e) {
              completer.completeError(
                  "Found VM Service URI but failed to connect: $e");
            });
            return; // Found VM Service URI, skip DTD check
          }
        }

        // Priority 2: DTD URI as fallback (ws://...=/ws)
        // Example: "ws://127.0.0.1:57868/8LD1UdC8wrc=/ws"
        if (line.contains('ws://') && line.contains('=/ws')) {
          final dtdRegex = RegExp(r'ws://[a-zA-Z0-9.:\-_/=]+/ws');
          final match = dtdRegex.firstMatch(line);
          if (match != null) {
            dtdUri = match.group(0)!;
            // Don't connect yet, wait for VM Service URI
            // If no VM Service URI found after 5 seconds, will timeout with helpful message
          }
        }

        // Capture error messages from Flutter output
        if (line.contains('[Flutter Error]') ||
            line.contains('Error:') ||
            line.contains('Exception:') ||
            line.contains('Failed to build') ||
            line.contains('Error launching application')) {
          errorLines.add(line);
        }
      });

      // Capture stderr (build errors, warnings)
      _flutterProcess!.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        // Collect all stderr output as potential errors
        if (line.trim().isNotEmpty) {
          errorLines.add(line);
        }
      });

      _flutterProcess!.exitCode.then((code) {
        if (!completer.isCompleted) {
          if (code != 0) {
            // Build failed, create detailed error response
            final errorMessage = errorLines.isNotEmpty
                ? errorLines.join('\n')
                : "Flutter app exited with code $code";

            // Build failed, complete with error marker
            completer.completeError({
              "success": false,
              "error": {
                "code": "E302",
                "message": "Flutter build/launch failed",
                "details": errorMessage,
                "exitCode": code,
              },
              "suggestions": _getBuildErrorSuggestions(errorMessage),
              "quick_fixes": _getQuickFixes(errorMessage, projectPath),
            });
          } else {
            completer.completeError(
                "Flutter app exited normally but no connection established");
          }
        }
        _flutterProcess = null;
      });

      try {
        final result = await completer.future
            .timeout(const Duration(seconds: 180)); // 3 minutes for slow builds
        return {
          "success": true,
          "message": result,
          "session_id": sessionId,
          "uri": _sessions[sessionId]?.vmServiceUri,
        };
      } on TimeoutException {
        // Check if we found DTD URI but no VM Service URI
        if (dtdUri != null) {
          return {
            "success": false,
            "error": {
              "code": "E301",
              "message": "Found DTD URI but no VM Service URI",
              "details":
                  "Flutter 3.x uses DTD protocol by default. VM Service URI not found in output.",
            },
            "found_uris": {"dtd": dtdUri},
            "suggestions": [
              "Flutter Skill requires VM Service URI, not DTD URI",
              "",
              "Option 1: Force VM Service protocol (recommended)",
              "Add to your flutter run command:",
              "  flutter run --vm-service-port=50000",
              "",
              "Option 2: Use Dart MCP for DTD-based testing",
              "  mcp__dart__connect_dart_tooling_daemon(uri: '$dtdUri')",
              "",
              "Option 3: Enable both protocols",
              "Check Flutter DevTools output for VM Service URI",
            ],
            "quick_fix":
                "Launch with: flutter run -d <device> --vm-service-port=50000",
          };
        }

        return {
          "success": false,
          "error": {
            "code": "E301",
            "message": "Timed out waiting for app to start (180s)",
          },
          "suggestions": [
            "The app may still be compiling. Try again or check flutter logs.",
            "Use scan_and_connect() after the app finishes launching.",
            "For faster startup, use 'flutter run' manually and then connect_app().",
          ],
        };
      } catch (e) {
        // Catch build errors from completeError
        if (e is Map) {
          return e; // Return the error map directly
        }
        // Fallback for other errors
        return {
          "success": false,
          "error": {
            "code": "E303",
            "message": "Launch failed: $e",
          },
        };
      }
    }

    if (name == 'start_bridge_listener') {
      final port = args['port'] as int? ?? bridgeDefaultPort;
      if (_webBridgeListener != null) {
        return {
          "success": true,
          "message": "Bridge listener already running",
          "port": _webBridgeListener!.port,
          "url": "ws://127.0.0.1:${_webBridgeListener!.port}",
          "has_client": _webBridgeListener!.hasClient,
        };
      }
      try {
        await startBridgeListener(port);
        return {
          "success": true,
          "port": port,
          "url": "ws://127.0.0.1:$port",
          "message":
              "Bridge listener started. Browser SDK can connect to ws://127.0.0.1:$port",
        };
      } catch (e) {
        return {
          "success": false,
          "error": "Failed to start bridge listener: $e"
        };
      }
    }

    if (name == 'stop_bridge_listener') {
      if (_webBridgeListener == null) {
        return {"success": true, "message": "No bridge listener running"};
      }
      await _webBridgeListener!.stop();
      _webBridgeListener = null;
      return {"success": true, "message": "Bridge listener stopped"};
    }

    if (name == 'scan_and_connect') {
      final portStart = args['port_start'] ?? 48000;
      final portEnd = args['port_end'] ?? 65000;
      final sessionId = args['session_id'] as String? ?? _generateSessionId();
      final scanFlavor = args['flavor'] as String?;
      final scanDeviceId = args['device_id'] as String?;

      // Auto-fix configuration if project_path is provided
      final projectPath = args['project_path'] as String?;
      if (projectPath != null) {
        try {
          await runSetup(projectPath, quiet: true);
        } catch (e) {
          // Continue even if setup fails
          print('Warning: Auto-setup failed: $e');
        }
      }

      // Check web bridge listener first
      if (_webBridgeListener != null && _webBridgeListener!.hasClient) {
        final existing = _sessions.values.where(
            (s) => s.deviceId == 'web' && s.port == _webBridgeListener!.port);
        if (existing.isNotEmpty) {
          _activeSessionId = existing.first.id;
          return {
            "success": true,
            "connected": "ws://127.0.0.1:${_webBridgeListener!.port}",
            "framework": "web",
            "session_id": existing.first.id,
            "active_session": true,
            "source": "bridge_listener",
          };
        }
        final driver = WebBridgeDriver(_webBridgeListener!);
        await driver.connect();
        _clients[sessionId] = driver;
        _sessions[sessionId] = SessionInfo(
          id: sessionId,
          name: args['name'] as String? ?? 'Web app (bridge listener)',
          projectPath: args['project_path'] as String? ?? 'web',
          deviceId: 'web',
          port: _webBridgeListener!.port!,
          vmServiceUri: 'ws://127.0.0.1:${_webBridgeListener!.port}',
        );
        _activeSessionId = sessionId;
        return {
          "success": true,
          "connected": "ws://127.0.0.1:${_webBridgeListener!.port}",
          "framework": "web",
          "session_id": sessionId,
          "active_session": true,
          "source": "bridge_listener",
        };
      }

      // Try bridge discovery first (cross-framework)
      final bridgeApps = await BridgeDiscovery.discoverAll();
      if (bridgeApps.isNotEmpty) {
        final bridgeApp = bridgeApps.first;

        // Disconnect old client for this session if exists
        if (_clients.containsKey(sessionId)) {
          await _clients[sessionId]!.disconnect();
        }

        var driver = BridgeDriver.fromInfo(bridgeApp);
        try {
          await driver.connect();
        } catch (_) {
          // Some frameworks (Tauri) use port+1 for WebSocket
          final altUri = 'ws://127.0.0.1:${bridgeApp.port + 1}';
          final altInfo = BridgeServiceInfo(
            framework: bridgeApp.framework,
            appName: bridgeApp.appName,
            platform: bridgeApp.platform,
            capabilities: bridgeApp.capabilities,
            sdkVersion: bridgeApp.sdkVersion,
            port: bridgeApp.port + 1,
            wsUri: altUri,
          );
          driver = BridgeDriver.fromInfo(altInfo);
          await driver.connect();
        }

        _clients[sessionId] = driver;
        _sessions[sessionId] = SessionInfo(
          id: sessionId,
          name:
              args['name'] as String? ?? '${bridgeApp.framework} app (bridge)',
          projectPath: args['project_path'] as String? ?? 'unknown',
          deviceId: bridgeApp.platform,
          port: bridgeApp.port,
          vmServiceUri: bridgeApp.wsUri,
        );
        _activeSessionId = sessionId;

        return {
          "success": true,
          "connected": bridgeApp.wsUri,
          "framework": bridgeApp.framework,
          "session_id": sessionId,
          "active_session": true,
          "bridge_apps": bridgeApps.map((a) => a.toJson()).toList(),
        };
      }

      // Fall back to VM Service discovery (Flutter), using process-based
      // discovery first so we can filter by flavor/device
      final flutterApps = await ProcessBasedDiscovery.discoverAll();
      String uri;
      if (flutterApps.isNotEmpty) {
        final selected = await ProcessBasedDiscovery.smartSelect(
          flutterApps,
          deviceId: scanDeviceId,
          flavor: scanFlavor,
        );
        if (selected == null) {
          return {"success": false, "message": "No app selected"};
        }
        uri = selected.vmServiceUri;
      } else {
        // Last resort: raw port scan
        final vmServices = await _scanVmServices(portStart, portEnd);
        if (vmServices.isEmpty) {
          return {
            "success": false,
            "message":
                "No running apps found (checked bridge ports and VM Service ports)"
          };
        }
        uri = vmServices.first;
      }

      // Clean up stale sessions, then disconnect old client for this session
      await _cleanupStaleSessions();
      if (_clients.containsKey(sessionId)) {
        await _clients[sessionId]!.disconnect();
      }

      final client = FlutterSkillClient(uri);
      await client.connect();

      // Store client and session info
      _clients[sessionId] = client;
      _sessions[sessionId] = SessionInfo(
        id: sessionId,
        name: args['name'] as String? ??
            'Scanned connection ${_sessions.length + 1}',
        projectPath: args['project_path'] as String? ?? 'unknown',
        deviceId: args['device_id'] as String? ?? 'unknown',
        port: int.tryParse(uri.split(':').last.split('/').first) ?? 0,
        vmServiceUri: uri,
      );

      // Always switch to the newly connected session
      _activeSessionId = sessionId;

      return {
        "success": true,
        "connected": uri,
        "framework": "Flutter",
        "session_id": sessionId,
        "active_session": true,
        "available": [uri]
      };
    }

    if (name == 'connect_by_pid') {
      final pid = args['pid'] as int;
      final sessionId = args['session_id'] as String? ?? _generateSessionId();

      // Use lsof to find which TCP port(s) the process is listening on
      final lsofResult = await Process.run('lsof', [
        '-a',
        '-p',
        '$pid',
        '-i',
        'TCP',
        '-s',
        'TCP:LISTEN',
        '-Fn',
      ]);
      final ports = <int>[];
      for (final line in lsofResult.stdout.toString().split('\n')) {
        // Lines like: n*:50000
        final match = RegExp(r':(\d+)$').firstMatch(line.trim());
        if (match != null) {
          final p = int.tryParse(match.group(1)!);
          if (p != null) ports.add(p);
        }
      }

      if (ports.isEmpty) {
        return {
          "success": false,
          "error": {
            "code": "E_PID_NO_PORT",
            "message": "No listening TCP ports found for PID $pid",
          },
          "suggestions": [
            "Verify the app is still running: kill -0 $pid",
            "Try scan_and_connect() instead",
          ],
        };
      }

      // Try each port — find the one that speaks VM Service
      await _cleanupStaleSessions();
      for (final port in ports) {
        final vmUris = await _scanVmServices(port, port);
        final vmUri = vmUris.isNotEmpty ? vmUris.first : null;
        if (vmUri == null) continue;

        try {
          if (_clients.containsKey(sessionId)) {
            await _clients[sessionId]!.disconnect();
          }
          final client = FlutterSkillClient(vmUri);
          await client.connect();
          _clients[sessionId] = client;
          _sessions[sessionId] = SessionInfo(
            id: sessionId,
            name: args['name'] as String? ?? 'PID $pid',
            projectPath: 'unknown',
            deviceId: 'unknown',
            port: port,
            vmServiceUri: vmUri,
          );
          _activeSessionId = sessionId;
          return {
            "success": true,
            "message": "Connected via PID $pid",
            "pid": pid,
            "uri": vmUri,
            "session_id": sessionId,
            "active_session": true,
          };
        } catch (_) {
          continue;
        }
      }

      return {
        "success": false,
        "error": {
          "code": "E_PID_CONNECT_FAILED",
          "message":
              "Found ports $ports for PID $pid but could not connect to VM Service",
        },
        "suggestions": [
          "The app may not have FlutterSkillBinding initialized",
          "Try: scan_and_connect()",
        ],
      };
    }

    if (name == 'list_running_apps') {
      final portStart = args['port_start'] ?? 50000;
      final portEnd = args['port_end'] ?? 50100;

      final vmServices = await _scanVmServices(portStart, portEnd);
      return {"apps": vmServices, "count": vmServices.length};
    }

    if (name == 'stop_app') {
      final sessionId = args['session_id'] as String? ?? _activeSessionId;

      if (sessionId != null && _clients.containsKey(sessionId)) {
        await _clients[sessionId]!.disconnect();
        _clients.remove(sessionId);
        _sessions.remove(sessionId);

        // Update active session
        if (_activeSessionId == sessionId) {
          _activeSessionId =
              _sessions.keys.isNotEmpty ? _sessions.keys.first : null;
        }
      }

      if (_flutterProcess != null) {
        _flutterProcess!.kill();
        _flutterProcess = null;
      }

      return {
        "success": true,
        "message": "App stopped",
        "session_id": sessionId,
        "active_session_id": _activeSessionId,
      };
    }

    if (name == 'disconnect') {
      final sessionId = args['session_id'] as String? ?? _activeSessionId;

      if (sessionId != null && _clients.containsKey(sessionId)) {
        final client = _clients[sessionId]!;

        // Clean up CDP driver reference
        if (client is CdpDriver && _cdpDriver == client) {
          _cdpDriver = null;
        }

        await client.disconnect();
        _clients.remove(sessionId);
        _sessions.remove(sessionId);

        // Update active session
        if (_activeSessionId == sessionId) {
          _activeSessionId =
              _sessions.keys.isNotEmpty ? _sessions.keys.first : null;
        }

        return {
          "success": true,
          "message": "Disconnected from session $sessionId",
          "active_session_id": _activeSessionId,
        };
      }

      return {
        "success": false,
        "error": {"message": "No active session or session not found"},
      };
    }

    if (name == 'get_connection_status') {
      final sessionId = args['session_id'] as String? ?? _activeSessionId;

      if (sessionId != null && _clients.containsKey(sessionId)) {
        final client = _clients[sessionId]!;
        final session = _sessions[sessionId];

        return {
          "connected": client.isConnected,
          "framework": client.frameworkName,
          "mode": client is CdpDriver
              ? "cdp"
              : (client is BridgeDriver ? "bridge" : "flutter"),
          "session_id": sessionId,
          "uri": client is FlutterSkillClient ? client.vmServiceUri : null,
          "session_info": session?.toJson(),
          "launched_app": _flutterProcess != null,
        };
      }

      // No active session - try to find running apps
      final vmServices = await _scanVmServices(50000, 50100);
      return {
        "connected": false,
        "session_id": null,
        "available_sessions": _sessions.length,
        "launched_app": _flutterProcess != null,
        "available_apps": vmServices,
        "suggestion": vmServices.isNotEmpty
            ? "Found ${vmServices.length} running app(s). Use scan_and_connect() to auto-connect."
            : "No running apps found. Use launch_app() to start one.",
      };
    }

    return null; // Not handled by this group
  }

  /// Remove sessions whose underlying connection is no longer alive.
  Future<void> _cleanupStaleSessions() async {
    final staleIds = <String>[];
    for (final entry in _clients.entries) {
      if (!entry.value.isConnected) {
        staleIds.add(entry.key);
      }
    }
    for (final id in staleIds) {
      try {
        await _clients[id]!.disconnect();
      } catch (_) {}
      _clients.remove(id);
      _sessions.remove(id);
      if (_activeSessionId == id) _activeSessionId = null;
    }
    if (_activeSessionId == null && _sessions.isNotEmpty) {
      _activeSessionId = _sessions.keys.first;
    }
  }

  /// Probe a WebSocket URI for the bridge protocol (JSON-RPC 2.0, not Dart VM
  /// Service). Returns BridgeServiceInfo if the host:port serves the
  /// /.flutter-skill health endpoint; null otherwise.
  ///
  /// This is how we distinguish C++ / React Native / Electron bridge URIs from
  /// Flutter VM Service URIs so that connect_app can route to the right driver.
  Future<BridgeServiceInfo?> _probeBridgeUri(String wsUri) async {
    try {
      final parsed = Uri.tryParse(wsUri);
      if (parsed == null) return null;
      final host = parsed.host.isEmpty ? '127.0.0.1' : parsed.host;
      final port = parsed.port;
      if (port == 0) return null;

      final client = HttpClient();
      client.connectionTimeout = const Duration(milliseconds: 300);
      final request = await client.get(host, port, '/.flutter-skill');
      final response = await request.close().timeout(const Duration(milliseconds: 500));
      if (response.statusCode == 200) {
        final body = await response
            .transform(const Utf8Decoder())
            .join()
            .timeout(const Duration(milliseconds: 300));
        final json = jsonDecode(body) as Map<String, dynamic>;
        if (json.containsKey('framework')) {
          client.close();
          return BridgeServiceInfo.fromHealthCheck(json, port);
        }
      }
      client.close();
    } catch (_) {}
    return null;
  }
}
