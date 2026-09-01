import 'bridge_discovery.dart';
import '../bridge/bridge_protocol.dart';
import 'dtd_service_discovery.dart';
import 'quick_port_check.dart';
import 'process_based_discovery.dart';

// Export DiscoveryResult for convenience
export 'dtd_service_discovery.dart' show DiscoveryResult;

/// Unified VM Service discovery mechanism
///
/// Smart strategy (by priority):
/// 1. Process-based discovery (fast) - extract from running Flutter processes
/// 2. Parallel port check (faster) - check common ports simultaneously
/// 3. DTD auto-discovery (automatic) - works with any launch method
/// 4. Port range scan (fallback) - last resort
class UnifiedDiscovery {
  /// Fast discovery of VM Service URI
  ///
  /// No need for .flutter_skill_uri file!
  /// No requirement for --vm-service-port=50000!
  static Future<DiscoveryResult> discover({
    bool verbose = false,
    String? deviceId,
    String? flavor,
  }) async {
    if (verbose) {
      print('🔍 Smart discovery of running apps...\n');
    }

    // ═══════════════════════════════════════
    // Strategy -1: Bridge discovery (cross-framework!)
    // ═══════════════════════════════════════
    if (verbose) {
      print(
          '📋 Strategy B: Bridge discovery (ports $bridgePortRangeStart-$bridgePortRangeEnd)...');
    }

    try {
      final bridgeApps = await BridgeDiscovery.discoverAll(verbose: verbose);

      if (bridgeApps.isNotEmpty) {
        final app = bridgeApps.first;
        if (verbose) {
          print('   ✅ Found ${bridgeApps.length} bridge app(s): $app\n');
        }
        return DiscoveryResult(
          success: true,
          bridgeUri: app.wsUri,
          discoveryMethod: 'bridge',
          message:
              'Discovered via bridge protocol (${app.framework} on ${app.platform})',
        );
      }

      if (verbose) {
        print('   ⚠️  No bridge apps found\n');
      }
    } catch (e) {
      if (verbose) {
        print('   ⚠️  Bridge discovery failed: $e\n');
      }
    }

    // ═══════════════════════════════════════
    // Strategy 0: Process-based discovery (most elegant!)
    // ═══════════════════════════════════════
    if (verbose) {
      print(
          '📋 Strategy 0: Process-based smart discovery (no port scanning)...');
    }

    try {
      final apps = await ProcessBasedDiscovery.discoverAll();

      if (apps.isNotEmpty) {
        // Smart selection or user selection
        final app = await ProcessBasedDiscovery.smartSelect(
          apps,
          deviceId: deviceId,
          flavor: flavor,
        );

        if (app != null) {
          if (verbose) {
            print(
                '   ✅ Found ${apps.length} app(s), selected: ${app.description}\n');
          }

          return DiscoveryResult(
            success: true,
            vmServiceUri: app.vmServiceUri,
            dtdUri: app.dtdUri,
            discoveryMethod: 'process_based',
            message: 'Discovered via process (${apps.length} app(s))',
          );
        }
      }

      if (verbose) {
        print('   ⚠️  No apps found via process discovery\n');
      }
    } catch (e) {
      if (verbose) {
        print('   ⚠️  Process discovery failed: $e\n');
      }
    }

    // ═══════════════════════════════════════
    // Strategy 1: Parallel port check (fast fallback)
    // ═══════════════════════════════════════
    if (verbose) {
      print(
          '📋 Strategy 1: Checking common ports in parallel (50000-50005)...');
    }

    final commonPorts = [50000, 50001, 50002, 50003, 50004, 50005];

    try {
      // Check all ports in parallel (much faster!)
      final result = await QuickPortCheck.checkPortsParallel(commonPorts);

      if (result != null) {
        // Extract port from URI
        final portMatch = RegExp(r':(\d+)/').firstMatch(result);
        final port = portMatch != null ? portMatch.group(1) : 'unknown';

        if (verbose) {
          print('   ✅ Found! Port $port\n');
        }

        return DiscoveryResult(
          success: true,
          vmServiceUri: result,
          discoveryMethod: 'parallel_port',
          message: 'Quick discovery via parallel port scan (port $port)',
        );
      }

      if (verbose) {
        print('   ⚠️  Common ports not found\n');
      }
    } catch (e) {
      if (verbose) {
        print('   ⚠️  Parallel port check failed: $e\n');
      }
    }

    // ═══════════════════════════════════════
    // Strategy 2: DTD auto-discovery (smart!)
    // ═══════════════════════════════════════
    if (verbose) {
      print('📋 Strategy 2: DTD auto-discovery...');
    }

    try {
      final dtdResult = await DtdServiceDiscovery.discover(
        portStart: 40000,
        portEnd:
            65535, // Extended to full port range to include DTD (usually 60000-65535)
      );

      if (dtdResult.success && dtdResult.vmServiceUri != null) {
        if (verbose) {
          print('   ✅ Discovered via DTD!\n');
          print('   DTD URI:        ${dtdResult.dtdUri}');
          print('   VM Service URI: ${dtdResult.vmServiceUri}\n');
        }
        return dtdResult;
      }

      if (verbose) {
        print('   ⚠️  DTD did not find VM Service\n');
      }
    } catch (e) {
      if (verbose) {
        print('   ⚠️  DTD discovery failed: $e\n');
      }
    }

    // ═══════════════════════════════════════
    // Strategy 3: Full port scan (last resort)
    // ═══════════════════════════════════════
    if (verbose) {
      print('📋 Strategy 3: Scanning port range (40000-65535)...');
      print('   (This may take a few seconds)\n');
    }

    final scanResult = await _scanVmServicePorts(
      portStart: 40000,
      portEnd: 65535,
      verbose: verbose,
    );

    if (scanResult.isNotEmpty) {
      if (verbose) {
        print('   ✅ Found ${scanResult.length} VM Service(s)\n');
      }
      return DiscoveryResult(
        success: true,
        vmServiceUri: scanResult.first,
        discoveryMethod: 'port_scan',
        message: 'Discovered via port scan (${scanResult.length} available)',
      );
    }

    // ═══════════════════════════════════════
    // All strategies failed
    // ═══════════════════════════════════════
    return DiscoveryResult(
      success: false,
      message: 'No running Flutter apps found',
      suggestions: const [
        'Please ensure a Flutter app is running',
        'Recommended launch: flutter_skill launch -d <device>',
        'Or manual launch: flutter run -d <device> --vm-service-port=50000',
      ],
    );
  }

  /// Scan port range for VM Service (using DTD scan directly)
  static Future<List<String>> _scanVmServicePorts({
    required int portStart,
    required int portEnd,
    bool verbose = false,
  }) async {
    // Use DTD to scan the entire range
    final result = await DtdServiceDiscovery.discover(
      portStart: portStart,
      portEnd: portEnd,
    );

    if (result.success && result.vmServiceUri != null) {
      return [result.vmServiceUri!];
    }

    return [];
  }
}
