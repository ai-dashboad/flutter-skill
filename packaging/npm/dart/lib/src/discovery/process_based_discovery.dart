import 'dart:io';

/// Process-based elegant discovery mechanism
///
/// No port scanning! Discovers apps by inspecting running Flutter processes
class ProcessBasedDiscovery {
  /// Discover all running Flutter apps
  static Future<List<FlutterApp>> discoverAll() async {
    final apps = <FlutterApp>[];

    try {
      // 1. Find all Flutter-related processes
      final result = await Process.run('ps', ['aux']);
      final output = result.stdout as String;
      final lines = output.split('\n');

      // 2. Find development-service processes (they have VM Service URI)
      for (final line in lines) {
        if (line.contains('development-service') &&
            line.contains('--vm-service-uri=') &&
            line.contains('--bind-port=')) {
          final app = _parseDevServiceLine(line);
          if (app != null) {
            apps.add(app);
          }
        }
      }

      // 3. Find devtools processes (they have DTD URI)
      final dtdUris = <int, String>{}; // port -> dtdUri
      for (final line in lines) {
        if (line.contains('devtools') && line.contains('--dtd-uri')) {
          final match = RegExp(r'--dtd-uri\s+(ws://[^\s]+)').firstMatch(line);
          final portMatch = RegExp(r'--bind-port=(\d+)').firstMatch(line);

          if (match != null && portMatch != null) {
            final dtdUri = match.group(1)!;
            final port = int.parse(portMatch.group(1)!);
            dtdUris[port] = dtdUri;
          }
        }
      }

      // 4. Associate DTD URIs with corresponding apps
      for (final app in apps) {
        if (dtdUris.containsKey(app.port)) {
          app.dtdUri = dtdUris[app.port];
        }
      }

      // 5. Try to find app project paths and device info
      await _enrichWithProjectPaths(apps, lines);
      await _enrichWithDeviceInfo(apps, lines);
    } catch (e) {
      print('Discovery failed: $e');
    }

    return apps;
  }

  /// Parse development-service process line
  static FlutterApp? _parseDevServiceLine(String line) {
    try {
      // Extract VM Service URI
      final vmMatch =
          RegExp(r'--vm-service-uri=(http://[^\s]+)').firstMatch(line);
      if (vmMatch == null) return null;

      var vmServiceUri = vmMatch.group(1)!;

      // Convert to WebSocket URI
      if (vmServiceUri.startsWith('http://')) {
        vmServiceUri = vmServiceUri.replaceFirst('http://', 'ws://');
        // Ensure it ends with /ws (but don't duplicate)
        if (vmServiceUri.endsWith('/')) {
          vmServiceUri = '${vmServiceUri}ws';
        } else if (!vmServiceUri.endsWith('/ws')) {
          vmServiceUri = '$vmServiceUri/ws';
        }
      }

      // Extract bind port
      final portMatch = RegExp(r'--bind-port=(\d+)').firstMatch(line);
      final port = portMatch != null ? int.parse(portMatch.group(1)!) : 0;

      // Extract process ID
      final parts = line.trim().split(RegExp(r'\s+'));
      final pid = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;

      return FlutterApp(
        vmServiceUri: vmServiceUri,
        port: port,
        pid: pid,
      );
    } catch (e) {
      return null;
    }
  }

  /// Try to find app project paths
  static Future<void> _enrichWithProjectPaths(
    List<FlutterApp> apps,
    List<String> psLines,
  ) async {
    // For each app, use lsof to get its working directory
    for (final app in apps) {
      if (app.pid > 0) {
        try {
          final result = await Process.run('lsof', [
            '-a', // AND logic
            '-p', '${app.pid}', // Process ID
            '-d', 'cwd', // Current working directory
            '-Fn', // Output format: n = name (path)
          ]);

          if (result.exitCode == 0) {
            final output = result.stdout as String;
            // lsof -Fn output format: n/path/to/directory
            final lines = output.split('\n');
            for (final line in lines) {
              if (line.startsWith('n')) {
                app.projectPath = line.substring(1); // Remove leading 'n'
                break;
              }
            }
          }
        } catch (e) {
          // lsof failed, skip
        }
      }
    }
  }

  /// Try to extract device information from flutter run commands
  static Future<void> _enrichWithDeviceInfo(
    List<FlutterApp> apps,
    List<String> psLines,
  ) async {
    // Map PIDs to their parent flutter run processes
    final pidToDevice = <int, String>{};
    final pidToFlavor = <int, String>{};

    for (final line in psLines) {
      // Look for flutter run commands with -d device flag
      if (line.contains('flutter') && line.contains('run')) {
        // Extract PID of flutter run process
        final parts = line.trim().split(RegExp(r'\s+'));
        final flutterPid = parts.length > 1 ? int.tryParse(parts[1]) : null;

        // Extract device from -d flag or --device flag
        final deviceMatch = RegExp(r'-d\s+"([^"]+)"').firstMatch(line) ??
            RegExp(r'-d\s+(\S+)').firstMatch(line) ??
            RegExp(r'--device[=\s]+"([^"]+)"').firstMatch(line) ??
            RegExp(r'--device[=\s]+(\S+)').firstMatch(line);

        if (deviceMatch != null && flutterPid != null) {
          final deviceId = deviceMatch.group(1)!;
          pidToDevice[flutterPid] = deviceId;
        }

        // Extract --flavor flag
        if (flutterPid != null) {
          final flavorMatch = RegExp(r'--flavor[=\s]+(\S+)').firstMatch(line);
          if (flavorMatch != null) {
            pidToFlavor[flutterPid] = flavorMatch.group(1)!;
          }
        }
      }
    }

    // Match development-service processes to their parent flutter run processes
    // by looking for parent process relationships
    for (final app in apps) {
      if (app.pid > 0) {
        try {
          // Get parent process ID
          final result =
              await Process.run('ps', ['-o', 'ppid=', '-p', '${app.pid}']);
          if (result.exitCode == 0) {
            final ppidStr = (result.stdout as String).trim();
            final ppid = int.tryParse(ppidStr);

            if (ppid != null && pidToDevice.containsKey(ppid)) {
              app.deviceId = pidToDevice[ppid];
            } else {
              // Try to infer device from VM Service URI or other heuristics
              if (app.port >= 50000) {
                for (final line in psLines) {
                  if (line.contains('${app.pid}')) {
                    if (line.contains('iPhone') || line.contains('iOS')) {
                      app.deviceId = 'iOS Simulator';
                    } else if (line.contains('Android') ||
                        line.contains('emulator')) {
                      app.deviceId = 'Android Emulator';
                    }
                    break;
                  }
                }
              }
            }
            if (ppid != null && pidToFlavor.containsKey(ppid)) {
              app.flavor = pidToFlavor[ppid];
            }
          }
        } catch (e) {
          // Failed to get parent PID, skip
        }
      }
    }
  }

  /// Smart app selection (based on current directory, device, and flavor)
  ///
  /// Priority ranking:
  /// 1. Exact directory match + device match + flavor match
  /// 2. Exact directory match + flavor match
  /// 3. Exact directory match + device match
  /// 4. Exact directory match
  /// 5. Prefix directory match + device/flavor match
  /// 6. Device match only
  /// 7. Most recently started (lowest PID)
  static Future<FlutterApp?> smartSelect(
    List<FlutterApp> apps, {
    String? cwd,
    String? deviceId,
    String? flavor,
  }) async {
    if (apps.isEmpty) return null;
    if (apps.length == 1) return apps.first;

    cwd ??= Directory.current.path;

    // Step 1: Match apps based on cwd (exact match)
    final exactMatches = <FlutterApp>[];
    for (final app in apps) {
      if (app.projectPath != null && app.projectPath == cwd) {
        exactMatches.add(app);
      }
    }

    // Step 2: Narrow exact matches by flavor, then device
    if (exactMatches.isNotEmpty) {
      // Apply flavor filter first (most specific)
      var candidates = flavor != null
          ? exactMatches
              .where((app) =>
                  app.flavor != null &&
                  app.flavor!.toLowerCase() == flavor.toLowerCase())
              .toList()
          : exactMatches;

      if (candidates.isEmpty)
        candidates = exactMatches; // fallback if no flavor match

      // Then apply device filter
      if (deviceId != null) {
        final deviceMatches = candidates
            .where((app) =>
                app.deviceId != null &&
                app.deviceId!.toLowerCase().contains(deviceId.toLowerCase()))
            .toList();
        if (deviceMatches.length == 1) return deviceMatches.first;
        if (deviceMatches.length > 1) {
          deviceMatches.sort((a, b) => a.pid.compareTo(b.pid));
          return deviceMatches.first;
        }
      }

      if (candidates.length == 1) return candidates.first;
      if (candidates.length > 1) {
        candidates.sort((a, b) => a.pid.compareTo(b.pid));
        // If flavor was the differentiator, pick best match; otherwise ask user
        if (flavor != null) return candidates.first;
        return await userSelect(candidates);
      }
    }

    // Step 4: Try prefix matching (subdirectory case)
    final prefixMatches = <FlutterApp>[];
    for (final app in apps) {
      if (app.projectPath != null &&
          (cwd.startsWith(app.projectPath!) ||
              app.projectPath!.startsWith(cwd))) {
        prefixMatches.add(app);
      }
    }

    // Step 5: Prefix match with device
    if (prefixMatches.isNotEmpty && deviceId != null) {
      final deviceMatches = prefixMatches
          .where((app) =>
              app.deviceId != null &&
              app.deviceId!.toLowerCase().contains(deviceId.toLowerCase()))
          .toList();

      if (deviceMatches.length == 1) {
        return deviceMatches.first;
      } else if (deviceMatches.length > 1) {
        deviceMatches.sort((a, b) => a.pid.compareTo(b.pid));
        return await userSelect(deviceMatches);
      }
    }

    // Step 6: Single prefix match
    if (prefixMatches.length == 1) {
      return prefixMatches.first;
    } else if (prefixMatches.isNotEmpty) {
      prefixMatches.sort((a, b) => a.pid.compareTo(b.pid));
      return await userSelect(prefixMatches);
    }

    // Step 7: No directory match, try device-only match
    if (deviceId != null) {
      final deviceMatches = apps
          .where((app) =>
              app.deviceId != null &&
              app.deviceId!.toLowerCase().contains(deviceId.toLowerCase()))
          .toList();

      if (deviceMatches.length == 1) {
        return deviceMatches.first;
      } else if (deviceMatches.isNotEmpty) {
        deviceMatches.sort((a, b) => a.pid.compareTo(b.pid));
        return await userSelect(deviceMatches);
      }
    }

    // Step 8: No matches, show all apps sorted by recency
    apps.sort((a, b) => a.pid.compareTo(b.pid));
    return await userSelect(apps);
  }

  /// List all apps for user selection
  static Future<FlutterApp?> userSelect(List<FlutterApp> apps) async {
    if (apps.isEmpty) return null;
    if (apps.length == 1) return apps.first;

    // Check if multiple apps are in the same location
    final sameLocation = apps.length > 1 &&
        apps.every((app) => app.projectPath == apps.first.projectPath);

    if (sameLocation) {
      print(
          '\n🔍 Found ${apps.length} Flutter apps running in the same location:\n');
      print('   ${apps.first.projectPath}\n');
    } else {
      print('\n🔍 Found ${apps.length} running Flutter apps:\n');
    }

    for (var i = 0; i < apps.length; i++) {
      final app = apps[i];
      if (sameLocation) {
        // Show simplified info when all in same location
        final parts = <String>[];
        if (app.deviceId != null) parts.add('📱 ${app.deviceId}');
        if (app.port > 0) parts.add('Port ${app.port}');
        if (parts.isEmpty) parts.add('PID ${app.pid}');
        print('${i + 1}. ${parts.join(' - ')}');
      } else {
        print('${i + 1}. ${app.description}');
      }
    }

    print('\nSelect app to connect (1-${apps.length}): ');

    final input = stdin.readLineSync();
    final choice = int.tryParse(input ?? '');

    if (choice != null && choice > 0 && choice <= apps.length) {
      return apps[choice - 1];
    }

    return null;
  }
}

/// Flutter app information
class FlutterApp {
  final String vmServiceUri;
  final int port;
  final int pid;
  String? dtdUri;
  String? projectPath;
  String? deviceId;
  String? flavor;

  FlutterApp({
    required this.vmServiceUri,
    required this.port,
    required this.pid,
    this.dtdUri,
    this.projectPath,
    this.deviceId,
    this.flavor,
  });

  String get description {
    final parts = <String>[];
    if (projectPath != null) {
      parts.add('📁 $projectPath');
    }
    if (deviceId != null) {
      parts.add('📱 $deviceId');
    }
    if (flavor != null) {
      parts.add('🍦 $flavor');
    }
    if (port > 0) parts.add('Port $port');
    if (parts.isEmpty) parts.add('PID $pid');
    return parts.join(' - ');
  }

  @override
  String toString() => 'FlutterApp(uri: $vmServiceUri, port: $port, pid: $pid)';
}
