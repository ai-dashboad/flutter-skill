import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Detected platform type for native interactions
enum NativePlatform { iosSimulator, androidEmulator, unknown }

/// Result of a native platform operation
class NativeResult {
  final bool success;
  final String? message;
  final String? base64Image;
  final String? filePath;
  final Map<String, dynamic>? metadata;

  NativeResult({
    required this.success,
    this.message,
    this.base64Image,
    this.filePath,
    this.metadata,
  });

  Map<String, dynamic> toJson() => {
        'success': success,
        if (message != null) 'message': message,
        if (base64Image != null) 'image': base64Image,
        if (filePath != null) 'file_path': filePath,
        if (metadata != null) ...metadata!,
      };
}

/// Abstract driver for native platform interactions.
/// Enables interaction with native OS views that are invisible to Flutter's VM Service.
abstract class NativeDriver {
  NativePlatform get platform;

  Future<NativeResult> screenshot({bool saveToFile = true});
  Future<NativeResult> tap(double x, double y);
  Future<NativeResult> inputText(String text);
  Future<NativeResult> swipe(
      double startX, double startY, double endX, double endY,
      {int durationMs = 300});
  Future<Map<String, bool>> checkToolAvailability();

  /// Get the accessibility tree snapshot (zero-invasion element discovery)
  Future<List<Map<String, dynamic>>> getAccessibilityTree() async => [];

  /// Find elements by role, name, or text
  Future<List<Map<String, dynamic>>> findElements({
    String? role,
    String? name,
    String? text,
  }) async =>
      [];

  /// Get text content of element at position
  Future<String?> getTextAt(double x, double y) async => null;

  /// Get all text visible on screen
  Future<String> getVisibleText() async => '';

  /// Get element attributes at position
  Future<Map<String, dynamic>> getElementAt(double x, double y) async => {};

  /// Long press at coordinates
  Future<NativeResult> longPress(double x, double y,
      {int durationMs = 1000}) async {
    return NativeResult(
        success: false, message: 'longPress not implemented for this platform');
  }

  /// Perform a preset gesture
  Future<NativeResult> gesture(String gestureName) async {
    return NativeResult(
        success: false, message: 'gesture not implemented for this platform');
  }

  /// Press a single key by name
  Future<NativeResult> pressKey(String key) async {
    return NativeResult(
        success: false, message: 'pressKey not implemented for this platform');
  }

  /// Press a key combination (e.g. "cmd+a")
  Future<NativeResult> keyCombo(String keys) async {
    return NativeResult(
        success: false, message: 'keyCombo not implemented for this platform');
  }

  /// Press a hardware button
  Future<NativeResult> hardwareButton(String button) async {
    return NativeResult(
        success: false,
        message: 'hardwareButton not implemented for this platform');
  }

  /// List available simulators/emulators
  static Future<Map<String, dynamic>> listDevices(
      {String platform = 'all'}) async {
    final result = <String, dynamic>{};

    if (platform == 'all' || platform == 'ios') {
      try {
        final proc =
            await Process.run('xcrun', ['simctl', 'list', 'devices', '-j']);
        if (proc.exitCode == 0) {
          final json = jsonDecode(proc.stdout as String);
          final devices = json['devices'] as Map<String, dynamic>;
          final iosDevices = <Map<String, dynamic>>[];
          for (final entry in devices.entries) {
            final runtime = entry.key;
            for (final device in (entry.value as List)) {
              iosDevices.add({
                'name': device['name'],
                'udid': device['udid'],
                'state': device['state'],
                'runtime': runtime.replaceAll(
                    'com.apple.CoreSimulator.SimRuntime.', ''),
              });
            }
          }
          result['ios'] = iosDevices;
        }
      } catch (_) {
        result['ios_error'] = 'xcrun simctl not available';
      }
    }

    if (platform == 'all' || platform == 'android') {
      try {
        final proc = await Process.run('adb', ['devices', '-l']);
        if (proc.exitCode == 0) {
          final lines = (proc.stdout as String)
              .split('\n')
              .where((l) => l.contains('\t') || l.contains('device '))
              .toList();
          final androidDevices = <Map<String, dynamic>>[];
          for (final line in lines) {
            if (line.trim().isEmpty || line.startsWith('List')) continue;
            final parts = line.trim().split(RegExp(r'\s+'));
            if (parts.length >= 2) {
              final serial = parts[0];
              final state = parts[1];
              String? model;
              String? device;
              for (final part in parts.skip(2)) {
                if (part.startsWith('model:')) {
                  model = part.substring(6);
                }
                if (part.startsWith('device:')) {
                  device = part.substring(7);
                }
              }
              androidDevices.add({
                'serial': serial,
                'state': state,
                if (model != null) 'model': model,
                if (device != null) 'device': device,
              });
            }
          }
          result['android'] = androidDevices;
        }
      } catch (_) {
        result['android_error'] = 'adb not available';
      }
    }

    return result;
  }

  /// Detect the platform from device_id or running environment
  static Future<NativePlatform> detectPlatform(String? deviceId) async {
    if (deviceId != null) {
      final lower = deviceId.toLowerCase();
      if (lower.contains('iphone') ||
          lower.contains('ipad') ||
          lower.contains('ios') ||
          lower.contains('simulator')) {
        return NativePlatform.iosSimulator;
      }
      if (lower.contains('android') ||
          lower.contains('emulator') ||
          lower.contains('pixel') ||
          lower.contains('sdk_gphone')) {
        return NativePlatform.androidEmulator;
      }
    }

    // Check if iOS Simulator is running
    try {
      final result =
          await Process.run('xcrun', ['simctl', 'list', 'devices', 'booted']);
      if (result.exitCode == 0 && result.stdout.toString().contains('Booted')) {
        return NativePlatform.iosSimulator;
      }
    } catch (_) {}

    // Check if Android emulator is running
    try {
      final result = await Process.run('adb', ['devices']);
      if (result.exitCode == 0 &&
          result.stdout.toString().contains('emulator')) {
        return NativePlatform.androidEmulator;
      }
    } catch (_) {}

    return NativePlatform.unknown;
  }

  /// Create the appropriate driver for the detected platform
  static Future<NativeDriver?> create(String? deviceId) async {
    final platform = await detectPlatform(deviceId);
    switch (platform) {
      case NativePlatform.iosSimulator:
        return IosSimulatorDriver();
      case NativePlatform.androidEmulator:
        return AndroidEmulatorDriver();
      case NativePlatform.unknown:
        return null;
    }
  }
}

// =============================================================================
// iOS Simulator Driver
// =============================================================================

class _Point {
  final double x;
  final double y;
  _Point(this.x, this.y);
}

class IosSimulatorDriver extends NativeDriver {
  String? _cachedUdid;
  String? _cachedBridgePath;
  // idb availability and scale factor are detected once and cached.
  bool? _idbAvailable;
  double? _cachedLogicalScale;

  @override
  NativePlatform get platform => NativePlatform.iosSimulator;

  /// Find the fs-ios-bridge binary (built from native/ios-hid/)
  Future<String?> _getBridgePath() async {
    if (_cachedBridgePath != null) return _cachedBridgePath;

    // Check common locations
    final candidates = [
      // Relative to the running executable
      '${File(Platform.resolvedExecutable).parent.path}/fs-ios-bridge',
      // In the source tree
      '${File(Platform.resolvedExecutable).parent.parent.path}/native/ios-hid/fs-ios-bridge',
      // Installed globally
      '/usr/local/bin/fs-ios-bridge',
      // In PATH
    ];

    for (final path in candidates) {
      if (await File(path).exists()) {
        _cachedBridgePath = path;
        return path;
      }
    }

    // Try PATH
    try {
      final result = await Process.run('which', ['fs-ios-bridge']);
      if (result.exitCode == 0) {
        _cachedBridgePath = (result.stdout as String).trim();
        return _cachedBridgePath;
      }
    } catch (_) {}

    return null;
  }

  /// Run fs-ios-bridge command and parse JSON output
  Future<Map<String, dynamic>?> _runBridge(List<String> args) async {
    final bridgePath = await _getBridgePath();
    if (bridgePath == null) return null;

    final udid = await _getBootedSimulatorUdid();
    final fullArgs = [...args, '--udid', udid];

    final result = await Process.run(bridgePath, fullArgs).timeout(
      const Duration(seconds: 15),
      onTimeout: () => ProcessResult(0, 1, '', 'Timeout'),
    );

    if (result.exitCode != 0) return null;

    try {
      return jsonDecode((result.stdout as String).trim())
          as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Check if HID bridge is available (preferred over osascript)
  Future<bool> _hasBridge() async => (await _getBridgePath()) != null;

  // ========== idb (iOS Development Bridge) integration ==========

  /// Run an idb command, using python3.13 to work around the Python 3.14
  /// asyncio regression in the fb-idb package.
  Future<ProcessResult> _runIdb(List<String> args) async {
    // Prefer python3.13 which is compatible with fb-idb 1.1.7.
    // Fall back to the idb binary in case a fixed version is installed.
    const py313 = '/opt/homebrew/bin/python3.13';
    final py313Exists = await File(py313).exists();
    if (py313Exists) {
      return Process.run(py313, [
        '-c',
        'import asyncio; asyncio.set_event_loop(asyncio.new_event_loop()); '
            'from idb.cli.main import main; main()',
        '--',
        ...args,
      ]).timeout(const Duration(seconds: 10),
          onTimeout: () => ProcessResult(0, 1, '', 'idb timeout'));
    }
    return Process.run('idb', args).timeout(
      const Duration(seconds: 10),
      onTimeout: () => ProcessResult(0, 1, '', 'idb timeout'),
    );
  }

  /// Returns true if idb is usable on this machine.
  Future<bool> _hasIdb() async {
    if (_idbAvailable != null) return _idbAvailable!;
    try {
      final result = await _runIdb(['list-targets', '--json']);
      _idbAvailable = result.exitCode == 0;
    } catch (_) {
      _idbAvailable = false;
    }
    return _idbAvailable!;
  }

  /// Get the logical scale factor (pixels per point) for the booted simulator.
  /// Used to convert device-pixel coordinates to idb logical-point coordinates.
  Future<double> _getLogicalScale() async {
    if (_cachedLogicalScale != null) return _cachedLogicalScale!;
    try {
      final udid = await _getBootedSimulatorUdid();
      final result = await _runIdb(['describe', '--udid', udid]);
      if (result.exitCode == 0) {
        final out = result.stdout as String;
        // Parse "Screen: <w> x <h> (logical)" or similar idb output.
        final match = RegExp(r'(\d+)\s*x\s*(\d+)\s*\(?logical').firstMatch(out);
        if (match != null) {
          final logicalWidth = double.parse(match.group(1)!);
          // Get pixel width from a simctl screenshot (fast, cached result).
          final shotPath = '${Directory.systemTemp.path}/fs_scale_probe.png';
          final shot = await Process.run(
              'xcrun', ['simctl', 'io', udid, 'screenshot', shotPath]);
          if (shot.exitCode == 0) {
            // Use `sips` (built-in macOS tool) to read pixel dimensions.
            final sips = await Process.run('sips', [
              '-g',
              'pixelWidth',
              shotPath,
            ]);
            final sipsOut = sips.stdout as String;
            final pixelMatch =
                RegExp(r'pixelWidth:\s*(\d+)').firstMatch(sipsOut);
            if (pixelMatch != null) {
              final pixelWidth = double.parse(pixelMatch.group(1)!);
              _cachedLogicalScale = pixelWidth / logicalWidth;
              return _cachedLogicalScale!;
            }
          }
        }
      }
    } catch (_) {}
    // Safe default: most modern iPhones are @3x.
    _cachedLogicalScale = 3.0;
    return _cachedLogicalScale!;
  }

  /// Get the UDID of the first booted simulator
  Future<String> _getBootedSimulatorUdid() async {
    if (_cachedUdid != null) return _cachedUdid!;
    final result = await Process.run(
      'xcrun',
      ['simctl', 'list', 'devices', 'booted', '-j'],
    );
    if (result.exitCode != 0) {
      throw Exception('No booted iOS Simulator found');
    }
    final json = jsonDecode(result.stdout as String);
    final devices = json['devices'] as Map<String, dynamic>;
    for (final runtime in devices.values) {
      for (final device in (runtime as List)) {
        if (device['state'] == 'Booted') {
          _cachedUdid = device['udid'] as String;
          return _cachedUdid!;
        }
      }
    }
    throw Exception('No booted iOS Simulator found');
  }

  @override
  Future<NativeResult> screenshot({bool saveToFile = true}) async {
    final udid = await _getBootedSimulatorUdid();
    final tempDir = Directory.systemTemp;
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final filePath = '${tempDir.path}/native_screenshot_$timestamp.png';

    final result = await Process.run(
      'xcrun',
      ['simctl', 'io', udid, 'screenshot', filePath],
    );

    if (result.exitCode != 0) {
      return NativeResult(
        success: false,
        message: 'Screenshot failed: ${result.stderr}',
      );
    }

    if (saveToFile) {
      return NativeResult(
        success: true,
        filePath: filePath,
        message: 'Native screenshot saved to $filePath',
      );
    }

    final bytes = await File(filePath).readAsBytes();
    final base64Image = base64.encode(bytes);
    await File(filePath).delete();
    return NativeResult(success: true, base64Image: base64Image);
  }

  @override
  Future<NativeResult> tap(double x, double y) async {
    // Use HID bridge if available (faster, more reliable)
    if (await _hasBridge()) {
      final result = await _runBridge(['tap', '$x', '$y']);
      if (result != null) {
        return NativeResult(
          success: result['success'] == true,
          message: result['message'] as String? ?? result['error'] as String?,
        );
      }
    }

    // idb is more reliable than the Accessibility API: it uses XCTest under the
    // hood and requires no coordinate mapping (operates in logical points).
    if (await _hasIdb()) {
      final udid = await _getBootedSimulatorUdid();
      final scale = await _getLogicalScale();
      final lx = (x / scale).roundToDouble();
      final ly = (y / scale).roundToDouble();
      final idbResult =
          await _runIdb(['ui', 'tap', '$lx', '$ly', '--udid', udid]);
      if (idbResult.exitCode == 0) {
        return NativeResult(
          success: true,
          message:
              'Tapped at device (${x.round()}, ${y.round()}) via idb (logical: $lx, $ly)',
          metadata: {
            'device_coords': {'x': x, 'y': y},
            'logical_coords': {'x': lx, 'y': ly},
            'backend': 'idb',
          },
        );
      }
      // idb failed — fall through to Accessibility API.
    }

    // Fallback: osascript approach
    // Map device pixel coordinates to screen coordinates for hit-testing
    final screenCoords = await _mapToScreenCoordinates(x, y);
    if (screenCoords == null) {
      return NativeResult(
        success: false,
        message: 'Failed to map device coordinates to screen coordinates. '
            'Ensure the Simulator window is visible and not minimized.',
      );
    }

    // Use macOS Accessibility API to find the element at the target position
    // and perform AXPress action on it. This works reliably on macOS 26+
    // where synthetic mouse events (CGEvent) no longer trigger Simulator touches.
    final sx = screenCoords.x.toStringAsFixed(1);
    final sy = screenCoords.y.toStringAsFixed(1);

    final result = await Process.run('osascript', [
      '-e',
      '''
tell application "Simulator" to activate
delay 0.3
tell application "System Events"
    tell process "Simulator"
        -- Find the iOSContentGroup
        set contentGroup to missing value
        repeat with elem in UI elements of window 1
            try
                if subrole of elem is "iOSContentGroup" then
                    set contentGroup to elem
                    exit repeat
                end if
            end try
        end repeat

        if contentGroup is missing value then
            return "error:No iOSContentGroup found"
        end if

        -- Find the element at the target position by searching the accessibility tree.
        -- Prioritize specific roles (AXButton, AXTextField, etc.) over generic AXGroup,
        -- and prefer leaf elements (no children) as they are the actual interactive controls.
        set targetX to $sx
        set targetY to $sy
        set bestMatch to missing value
        set bestScore to -1

        set allElems to entire contents of contentGroup
        repeat with elem in allElems
            try
                set pos to position of elem
                set sz to size of elem
                set eLeft to item 1 of pos
                set eTop to item 2 of pos
                set eWidth to item 1 of sz
                set eHeight to item 2 of sz

                -- Check if target point is within this element's bounds
                if targetX >= eLeft and targetX <= (eLeft + eWidth) and targetY >= eTop and targetY <= (eTop + eHeight) then
                    set acts to name of actions of elem
                    if acts contains "AXPress" then
                        -- Score: higher = better match
                        -- Leaf elements (no children) get 1000 bonus
                        -- Specific roles (AXButton, AXTextField, etc.) get 500 bonus
                        -- Smaller area gets higher score (inverse area)
                        set area to eWidth * eHeight
                        set score to 0

                        set childCount to 0
                        try
                            set childCount to count of UI elements of elem
                        end try
                        if childCount is 0 then set score to score + 1000

                        set elemRole to role of elem
                        if elemRole is "AXButton" or elemRole is "AXTextField" or elemRole is "AXLink" or elemRole is "AXMenuItem" or elemRole is "AXCheckBox" or elemRole is "AXRadioButton" or elemRole is "AXSlider" then
                            set score to score + 500
                        end if

                        -- Smaller area = higher score (use inverse, max 499)
                        if area > 0 then
                            set areaScore to (100000 / area)
                            if areaScore > 499 then set areaScore to 499
                            set score to score + areaScore
                        end if

                        if score > bestScore then
                            set bestMatch to elem
                            set bestScore to score
                        end if
                    end if
                end if
            end try
        end repeat

        if bestMatch is missing value then
            return "error:No tappable element found at (" & targetX & ", " & targetY & ")"
        end if

        perform action "AXPress" of bestMatch
        set matchDesc to ""
        try
            set matchDesc to description of bestMatch
        end try
        set matchRole to ""
        try
            set matchRole to role of bestMatch
        end try
        return "ok:" & matchRole & " - " & matchDesc
    end tell
end tell
''',
    ]);

    if (result.exitCode != 0) {
      return NativeResult(
        success: false,
        message: 'Tap failed: ${result.stderr}',
      );
    }

    final output = (result.stdout as String).trim();
    if (output.startsWith('error:')) {
      return NativeResult(
        success: false,
        message: output.substring(6),
      );
    }

    final elementDesc = output.startsWith('ok:') ? output.substring(3) : '';
    return NativeResult(
      success: true,
      message:
          'Tapped at device (${x.round()}, ${y.round()}) -> element: $elementDesc',
      metadata: {
        'device_coords': {'x': x, 'y': y},
        'element': elementDesc,
      },
    );
  }

  @override
  Future<NativeResult> inputText(String text) async {
    final udid = await _getBootedSimulatorUdid();

    // idb text injection is the cleanest approach: no clipboard side-effects
    // and no "Allow Paste" dialog to dismiss.
    if (await _hasIdb()) {
      final idbResult = await _runIdb(['ui', 'text', text, '--udid', udid]);
      if (idbResult.exitCode == 0) {
        return NativeResult(
          success: true,
          message: 'Entered text via idb: "$text"',
          metadata: {'backend': 'idb'},
        );
      }
    }

    // Copy text to simulator pasteboard
    final process = await Process.start(
      'xcrun',
      ['simctl', 'pbcopy', udid],
    );
    process.stdin.write(text);
    await process.stdin.close();
    final exitCode = await process.exitCode;

    if (exitCode != 0) {
      return NativeResult(
        success: false,
        message: 'Failed to copy text to pasteboard',
      );
    }

    // Bring Simulator to front and paste using Cmd+V via AppleScript
    await Process.run('osascript', [
      '-e',
      'tell application "Simulator" to activate',
    ]);
    await Future.delayed(const Duration(milliseconds: 200));

    // Use System Events keystroke for Cmd+V (built-in, no external tools needed)
    final pasteResult = await Process.run('osascript', [
      '-e',
      'tell application "System Events" to keystroke "v" using command down',
    ]);

    if (pasteResult.exitCode != 0) {
      return NativeResult(
        success: false,
        message: 'Paste failed: ${pasteResult.stderr}',
      );
    }

    // Wait for potential iOS paste confirmation dialog and auto-accept it.
    // iOS 16+ shows "Allow Paste" dialog when pasting from external sources.
    await Future.delayed(const Duration(milliseconds: 500));
    await _dismissPasteDialog();

    return NativeResult(
      success: true,
      message: 'Entered text via pasteboard: "$text"',
    );
  }

  @override
  Future<NativeResult> swipe(
    double startX,
    double startY,
    double endX,
    double endY, {
    int durationMs = 300,
  }) async {
    // Use HID bridge if available
    if (await _hasBridge()) {
      final result = await _runBridge([
        'swipe',
        '$startX',
        '$startY',
        '$endX',
        '$endY',
        '--duration',
        '$durationMs',
      ]);
      if (result != null) {
        return NativeResult(
          success: result['success'] == true,
          message: result['message'] as String? ?? result['error'] as String?,
        );
      }
    }

    // idb swipe is more reliable (XCTest-backed, no coordinate mapping needed).
    if (await _hasIdb()) {
      final udid = await _getBootedSimulatorUdid();
      final scale = await _getLogicalScale();
      final lx1 = (startX / scale).roundToDouble();
      final ly1 = (startY / scale).roundToDouble();
      final lx2 = (endX / scale).roundToDouble();
      final ly2 = (endY / scale).roundToDouble();
      final duration =
          (durationMs / 1000.0).toStringAsFixed(2); // idb expects seconds
      final idbResult = await _runIdb([
        'ui',
        'swipe',
        '$lx1',
        '$ly1',
        '$lx2',
        '$ly2',
        '--duration',
        duration,
        '--udid',
        udid,
      ]);
      if (idbResult.exitCode == 0) {
        return NativeResult(
          success: true,
          message: 'Swiped via idb',
          metadata: {'backend': 'idb'},
        );
      }
    }

    // Fallback: osascript approach
    // Determine scroll direction from the swipe vector
    final deltaY = endY - startY;

    // Map start coordinates to find the scrollable element
    final screenCoords = await _mapToScreenCoordinates(startX, startY);
    if (screenCoords == null) {
      return NativeResult(
        success: false,
        message: 'Failed to map coordinates',
      );
    }

    // Use accessibility scroll actions. If swiping up (deltaY < 0),
    // the content should scroll down (reveal content below).
    // AXScrollUpByPage scrolls content UP (user swipes up).
    final scrollAction = deltaY < 0 ? 'AXScrollUpByPage' : 'AXScrollDownByPage';
    final sx = screenCoords.x.toStringAsFixed(1);
    final sy = screenCoords.y.toStringAsFixed(1);

    final result = await Process.run('osascript', [
      '-e',
      '''
tell application "Simulator" to activate
delay 0.3
tell application "System Events"
    tell process "Simulator"
        set contentGroup to missing value
        repeat with elem in UI elements of window 1
            try
                if subrole of elem is "iOSContentGroup" then
                    set contentGroup to elem
                    exit repeat
                end if
            end try
        end repeat

        if contentGroup is missing value then
            return "error:No iOSContentGroup found"
        end if

        -- Find a scrollable element at the target position
        set targetX to $sx
        set targetY to $sy
        set scrollTarget to missing value

        set allElems to entire contents of contentGroup
        repeat with elem in allElems
            try
                set pos to position of elem
                set sz to size of elem
                set eLeft to item 1 of pos
                set eTop to item 2 of pos
                set eWidth to item 1 of sz
                set eHeight to item 2 of sz

                if targetX >= eLeft and targetX <= (eLeft + eWidth) and targetY >= eTop and targetY <= (eTop + eHeight) then
                    set acts to name of actions of elem
                    if acts contains "$scrollAction" then
                        set scrollTarget to elem
                        -- Don't break - keep looking for more specific (inner) scrollable element
                    end if
                end if
            end try
        end repeat

        if scrollTarget is missing value then
            return "error:No scrollable element found at (" & targetX & ", " & targetY & ")"
        end if

        perform action "$scrollAction" of scrollTarget
        return "ok:scrolled"
    end tell
end tell
''',
    ]);

    if (result.exitCode != 0) {
      return NativeResult(
        success: false,
        message: 'Swipe failed: ${result.stderr}',
      );
    }

    final output = (result.stdout as String).trim();
    if (output.startsWith('error:')) {
      return NativeResult(
        success: false,
        message: output.substring(6),
      );
    }

    return NativeResult(
      success: true,
      message:
          'Swiped from (${startX.round()},${startY.round()}) to (${endX.round()},${endY.round()})',
    );
  }

  @override
  Future<Map<String, bool>> checkToolAvailability() async {
    return {
      'xcrun_simctl': await _isCommandAvailable('xcrun'),
      'osascript': await _isCommandAvailable('osascript'),
      'idb': await _hasIdb(),
    };
  }

  /// Return device description and idb availability for the MCP `idb_describe` tool.
  Future<Map<String, dynamic>> describe() async {
    final idbOk = await _hasIdb();
    if (!idbOk) {
      return {
        'idb_available': false,
        'error': 'idb not available. Install with: pip3 install fb-idb\n'
            'Requires Python 3.13 at /opt/homebrew/bin/python3.13',
        'fallback':
            'native_tap/swipe/input_text will use macOS Accessibility API instead.',
      };
    }

    final udid = await _getBootedSimulatorUdid();
    final scale = await _getLogicalScale();
    final idbResult = await _runIdb(['describe', '--udid', udid]);
    final rawDescription =
        idbResult.exitCode == 0 ? (idbResult.stdout as String).trim() : null;

    return {
      'idb_available': true,
      'udid': udid,
      'scale_factor': scale,
      'description': rawDescription,
      'note':
          'native_tap/swipe/input_text automatically use idb when available.',
    };
  }

  // ========== Paste Dialog Handling ==========

  /// Dismiss the iOS paste confirmation dialog if present.
  /// iOS 16+ shows "Allow Paste" when pasting from external sources.
  Future<void> _dismissPasteDialog() async {
    await Process.run('osascript', [
      '-e',
      '''
tell application "System Events"
    tell process "Simulator"
        set contentGroup to missing value
        repeat with elem in UI elements of window 1
            try
                if subrole of elem is "iOSContentGroup" then
                    set contentGroup to elem
                    exit repeat
                end if
            end try
        end repeat

        if contentGroup is missing value then return

        -- Search for "Allow Paste" button in the accessibility tree
        set allElems to entire contents of contentGroup
        repeat with elem in allElems
            try
                if role of elem is "AXButton" and description of elem is "Allow Paste" then
                    perform action "AXPress" of elem
                    return
                end if
            end try
        end repeat
    end tell
end tell
''',
    ]);
  }

  // ========== Coordinate Mapping ==========

  /// Map device pixel coordinates to macOS screen coordinates.
  /// Uses the iOSContentGroup accessibility element for precise bounds,
  /// and simctl screenshot for device pixel dimensions.
  Future<_Point?> _mapToScreenCoordinates(
      double deviceX, double deviceY) async {
    // Get content area position and size (always fresh, no caching
    // since the window can move between operations)
    final contentResult = await Process.run('osascript', [
      '-l',
      'JavaScript',
      '-e',
      '''
var app = Application("System Events");
var sim = app.processes.byName("Simulator");
var win = sim.windows[0];
var elems = win.uiElements();
var result = "notfound";
for (var i = 0; i < elems.length; i++) {
  try {
    if (elems[i].subrole() === "iOSContentGroup") {
      var pos = elems[i].position();
      var sz = elems[i].size();
      result = pos[0] + "," + pos[1] + "," + sz[0] + "," + sz[1];
      break;
    }
  } catch(e) {}
}
result;
''',
    ]);
    if (contentResult.exitCode != 0) return null;

    final contentStr = (contentResult.stdout as String).trim();
    if (contentStr == 'notfound') return null;

    final parts = contentStr.split(',');
    if (parts.length != 4) return null;
    final contentLeft = double.tryParse(parts[0]) ?? 0;
    final contentTop = double.tryParse(parts[1]) ?? 0;
    final contentWidth = double.tryParse(parts[2]) ?? 0;
    final contentHeight = double.tryParse(parts[3]) ?? 0;

    // Get device pixel resolution from simctl screenshot
    final udid = await _getBootedSimulatorUdid();
    final tempPath = '${Directory.systemTemp.path}/_coord_calibration.png';
    final ssResult = await Process.run(
      'xcrun',
      ['simctl', 'io', udid, 'screenshot', tempPath],
    );
    if (ssResult.exitCode != 0) return null;

    final file = File(tempPath);
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    await file.delete();

    final dimensions = _readPngDimensions(bytes);
    if (dimensions == null) return null;

    // Calculate scale and map coordinates
    final scaleX = contentWidth / dimensions.x;
    final scaleY = contentHeight / dimensions.y;

    return _Point(
      contentLeft + (deviceX * scaleX),
      contentTop + (deviceY * scaleY),
    );
  }

  /// Read width and height from PNG IHDR chunk (bytes 16-23, big-endian)
  _Point? _readPngDimensions(Uint8List bytes) {
    if (bytes.length < 24) return null;
    if (bytes[0] != 0x89 ||
        bytes[1] != 0x50 ||
        bytes[2] != 0x4E ||
        bytes[3] != 0x47) {
      return null;
    }
    final width =
        (bytes[16] << 24 | bytes[17] << 16 | bytes[18] << 8 | bytes[19])
            .toDouble();
    final height =
        (bytes[20] << 24 | bytes[21] << 16 | bytes[22] << 8 | bytes[23])
            .toDouble();
    return _Point(width, height);
  }

  // ─── Accessibility Tree (Zero-Invasion) ────────────────────────────

  @override
  Future<List<Map<String, dynamic>>> getAccessibilityTree() async {
    final result = await Process.run('osascript', [
      '-l',
      'JavaScript',
      '-e',
      '''
const app = Application("System Events").processes.byName("Simulator");
const win = app.windows[0];

// Find iOSContentGroup
let contentGroup = null;
const elems = win.uiElements();
for (let i = 0; i < elems.length; i++) {
  try {
    if (elems[i].subrole() === "iOSContentGroup") {
      contentGroup = elems[i];
      break;
    }
  } catch(e) {}
}
if (!contentGroup) { JSON.stringify([]); }

// Recursively collect all elements
function collectElements(elem, depth) {
  const results = [];
  try {
    const role = elem.role ? elem.role() : "";
    const name = elem.name ? elem.name() : "";
    const value = elem.value ? elem.value() : "";
    const desc = elem.description ? elem.description() : "";
    const enabled = elem.enabled ? elem.enabled() : true;
    const focused = elem.focused ? elem.focused() : false;
    let pos = null, sz = null;
    try { pos = elem.position(); sz = elem.size(); } catch(e) {}

    // Map AX roles to semantic roles
    let semanticRole = "";
    if (role === "AXButton") semanticRole = "button";
    else if (role === "AXTextField" || role === "AXTextArea") semanticRole = "textbox";
    else if (role === "AXStaticText") semanticRole = "text";
    else if (role === "AXLink") semanticRole = "link";
    else if (role === "AXImage") semanticRole = "image";
    else if (role === "AXCheckBox") semanticRole = "checkbox";
    else if (role === "AXRadioButton") semanticRole = "radio";
    else if (role === "AXSlider") semanticRole = "slider";
    else if (role === "AXSwitch" || role === "AXToggle") semanticRole = "switch";
    else if (role === "AXTabGroup") semanticRole = "tablist";
    else if (role === "AXTab") semanticRole = "tab";
    else if (role === "AXTable" || role === "AXList") semanticRole = "list";
    else if (role === "AXCell" || role === "AXRow") semanticRole = "listitem";
    else if (role === "AXScrollArea") semanticRole = "scrollbar";
    else if (role === "AXNavigationBar" || role === "AXToolbar") semanticRole = "navigation";
    else if (role === "AXGroup") semanticRole = "group";
    else semanticRole = role.replace("AX", "").toLowerCase();

    const displayName = name || desc || value || "";
    if (displayName || semanticRole === "button" || semanticRole === "textbox" ||
        semanticRole === "link" || semanticRole === "checkbox" || semanticRole === "switch") {
      results.push({
        role: semanticRole,
        axRole: role,
        name: displayName,
        value: (value && value !== name) ? String(value) : "",
        enabled: enabled,
        focused: focused,
        x: pos ? pos[0] : 0,
        y: pos ? pos[1] : 0,
        width: sz ? sz[0] : 0,
        height: sz ? sz[1] : 0,
        depth: depth
      });
    }

    // Recurse into children (limit depth to avoid slowness)
    if (depth < 10) {
      try {
        const children = elem.uiElements();
        for (let i = 0; i < children.length; i++) {
          const childResults = collectElements(children[i], depth + 1);
          for (let j = 0; j < childResults.length; j++) {
            results.push(childResults[j]);
          }
        }
      } catch(e) {}
    }
  } catch(e) {}
  return results;
}

const tree = collectElements(contentGroup, 0);
JSON.stringify(tree);
''',
    ]).timeout(const Duration(seconds: 15), onTimeout: () {
      return ProcessResult(0, 1, '[]', 'Timeout');
    });

    if (result.exitCode != 0) return [];
    try {
      final list = jsonDecode((result.stdout as String).trim()) as List;
      return list.cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  @override
  Future<List<Map<String, dynamic>>> findElements({
    String? role,
    String? name,
    String? text,
  }) async {
    final tree = await getAccessibilityTree();
    return tree.where((el) {
      if (role != null && el['role'] != role) return false;
      if (name != null) {
        final elName = (el['name'] as String? ?? '').toLowerCase();
        if (!elName.contains(name.toLowerCase())) return false;
      }
      if (text != null) {
        final elName = (el['name'] as String? ?? '').toLowerCase();
        final elValue = (el['value'] as String? ?? '').toLowerCase();
        if (!elName.contains(text.toLowerCase()) &&
            !elValue.contains(text.toLowerCase())) return false;
      }
      return true;
    }).toList();
  }

  @override
  Future<String?> getTextAt(double x, double y) async {
    final tree = await getAccessibilityTree();
    for (final el in tree.reversed) {
      final ex = (el['x'] as num?)?.toDouble() ?? 0;
      final ey = (el['y'] as num?)?.toDouble() ?? 0;
      final ew = (el['width'] as num?)?.toDouble() ?? 0;
      final eh = (el['height'] as num?)?.toDouble() ?? 0;
      if (x >= ex && x <= ex + ew && y >= ey && y <= ey + eh) {
        final name = el['name'] as String? ?? '';
        if (name.isNotEmpty) return name;
      }
    }
    return null;
  }

  @override
  Future<String> getVisibleText() async {
    final tree = await getAccessibilityTree();
    final texts = tree
        .where((el) =>
            (el['role'] == 'text' ||
                el['role'] == 'button' ||
                el['role'] == 'link') &&
            (el['name'] as String? ?? '').isNotEmpty)
        .map((el) => el['name'] as String)
        .toList();
    return texts.join('\n');
  }

  @override
  Future<Map<String, dynamic>> getElementAt(double x, double y) async {
    final tree = await getAccessibilityTree();
    Map<String, dynamic>? best;
    double bestArea = double.infinity;

    for (final el in tree) {
      final ex = (el['x'] as num?)?.toDouble() ?? 0;
      final ey = (el['y'] as num?)?.toDouble() ?? 0;
      final ew = (el['width'] as num?)?.toDouble() ?? 0;
      final eh = (el['height'] as num?)?.toDouble() ?? 0;
      if (x >= ex && x <= ex + ew && y >= ey && y <= ey + eh) {
        final area = ew * eh;
        if (area < bestArea && area > 0) {
          bestArea = area;
          best = el;
        }
      }
    }
    return best ?? {};
  }

  /// Tap element by name/role (zero-invasion alternative to coordinate tap)
  Future<NativeResult> tapByName(String name, {String? role}) async {
    final elements = await findElements(name: name, role: role);
    if (elements.isEmpty) {
      return NativeResult(
        success: false,
        message: 'Element not found: $name',
      );
    }
    final el = elements.first;
    final x = (el['x'] as num).toDouble() + (el['width'] as num).toDouble() / 2;
    final y =
        (el['y'] as num).toDouble() + (el['height'] as num).toDouble() / 2;
    return tap(x, y);
  }

  @override
  Future<NativeResult> longPress(double x, double y,
      {int durationMs = 1000}) async {
    // Use HID bridge if available (faster, more reliable)
    if (await _hasBridge()) {
      final br = await _runBridge(
          ['long-press', '$x', '$y', '--duration', '$durationMs']);
      if (br != null) {
        return NativeResult(
          success: br['success'] == true,
          message: br['message'] as String? ?? br['error'] as String?,
        );
      }
    }
    // Fallback: osascript
    final screenCoords = await _mapToScreenCoordinates(x, y);
    if (screenCoords == null) {
      return NativeResult(
        success: false,
        message: 'Failed to map device coordinates to screen coordinates.',
      );
    }

    final sx = screenCoords.x.toStringAsFixed(1);
    final sy = screenCoords.y.toStringAsFixed(1);
    final durationSec = (durationMs / 1000.0).toStringAsFixed(2);

    final result = await Process.run('osascript', [
      '-e',
      '''
tell application "Simulator" to activate
delay 0.3
tell application "System Events"
    tell process "Simulator"
        set contentGroup to missing value
        repeat with elem in UI elements of window 1
            try
                if subrole of elem is "iOSContentGroup" then
                    set contentGroup to elem
                    exit repeat
                end if
            end try
        end repeat

        if contentGroup is missing value then
            return "error:No iOSContentGroup found"
        end if

        set targetX to $sx
        set targetY to $sy
        set bestMatch to missing value
        set bestArea to 999999999

        set allElems to entire contents of contentGroup
        repeat with elem in allElems
            try
                set pos to position of elem
                set sz to size of elem
                set eLeft to item 1 of pos
                set eTop to item 2 of pos
                set eWidth to item 1 of sz
                set eHeight to item 2 of sz

                if targetX >= eLeft and targetX <= (eLeft + eWidth) and targetY >= eTop and targetY <= (eTop + eHeight) then
                    set area to eWidth * eHeight
                    if area > 0 and area < bestArea then
                        set bestArea to area
                        set bestMatch to elem
                    end if
                end if
            end try
        end repeat

        if bestMatch is missing value then
            return "error:No element found at (" & targetX & ", " & targetY & ")"
        end if

        -- Perform long press via mouse events on the element position
        set pos to position of bestMatch
        set sz to size of bestMatch
        set cx to (item 1 of pos) + ((item 1 of sz) / 2)
        set cy to (item 2 of pos) + ((item 2 of sz) / 2)

        -- Use click and hold via mouse down, delay, mouse up
        tell application "System Events"
            click at {cx, cy}
        end tell
        delay $durationSec

        set matchRole to ""
        try
            set matchRole to role of bestMatch
        end try
        return "ok:" & matchRole
    end tell
end tell
''',
    ]).timeout(
      Duration(milliseconds: durationMs + 10000),
      onTimeout: () => ProcessResult(0, 1, '', 'Timeout'),
    );

    if (result.exitCode != 0) {
      return NativeResult(
          success: false, message: 'Long press failed: ${result.stderr}');
    }

    final output = (result.stdout as String).trim();
    if (output.startsWith('error:')) {
      return NativeResult(success: false, message: output.substring(6));
    }

    return NativeResult(
      success: true,
      message:
          'Long pressed at (${x.round()}, ${y.round()}) for ${durationMs}ms',
    );
  }

  @override
  Future<NativeResult> gesture(String gestureName) async {
    // Use HID bridge if available
    if (await _hasBridge()) {
      final br = await _runBridge(['gesture', gestureName]);
      if (br != null) {
        return NativeResult(
          success: br['success'] == true,
          message: br['message'] as String? ?? br['error'] as String?,
        );
      }
    }
    // Fallback: For scroll gestures, use AX scroll actions
    if (gestureName.startsWith('scroll_')) {
      String scrollAction;
      switch (gestureName) {
        case 'scroll_up':
          scrollAction = 'AXScrollUpByPage';
          break;
        case 'scroll_down':
          scrollAction = 'AXScrollDownByPage';
          break;
        case 'scroll_left':
          scrollAction = 'AXScrollLeftByPage';
          break;
        case 'scroll_right':
          scrollAction = 'AXScrollRightByPage';
          break;
        default:
          return NativeResult(
              success: false, message: 'Unknown gesture: $gestureName');
      }

      final result = await Process.run('osascript', [
        '-e',
        '''
tell application "Simulator" to activate
delay 0.3
tell application "System Events"
    tell process "Simulator"
        set contentGroup to missing value
        repeat with elem in UI elements of window 1
            try
                if subrole of elem is "iOSContentGroup" then
                    set contentGroup to elem
                    exit repeat
                end if
            end try
        end repeat

        if contentGroup is missing value then
            return "error:No iOSContentGroup found"
        end if

        -- Find scrollable element
        set scrollTarget to missing value
        set allElems to entire contents of contentGroup
        repeat with elem in allElems
            try
                set acts to name of actions of elem
                if acts contains "$scrollAction" then
                    set scrollTarget to elem
                end if
            end try
        end repeat

        if scrollTarget is missing value then
            return "error:No scrollable element found for $scrollAction"
        end if

        perform action "$scrollAction" of scrollTarget
        return "ok:$gestureName"
    end tell
end tell
''',
      ]).timeout(
        const Duration(seconds: 15),
        onTimeout: () => ProcessResult(0, 1, '', 'Timeout'),
      );

      if (result.exitCode != 0) {
        return NativeResult(
            success: false, message: 'Gesture failed: ${result.stderr}');
      }
      final output = (result.stdout as String).trim();
      if (output.startsWith('error:')) {
        return NativeResult(success: false, message: output.substring(6));
      }
      return NativeResult(
          success: true, message: 'Performed gesture: $gestureName');
    }

    // For edge swipes and pull_to_refresh, get content bounds and simulate
    if (gestureName == 'pull_to_refresh') {
      // Pull to refresh = scroll down at top of content
      return gesture('scroll_down');
    }

    // Edge swipes: use screen coordinate swipes
    if (gestureName == 'edge_swipe_left' || gestureName == 'edge_swipe_right') {
      final contentResult = await Process.run('osascript', [
        '-l',
        'JavaScript',
        '-e',
        '''
var app = Application("System Events").processes.byName("Simulator");
var win = app.windows[0];
var elems = win.uiElements();
for (var i = 0; i < elems.length; i++) {
  try {
    if (elems[i].subrole() === "iOSContentGroup") {
      var pos = elems[i].position();
      var sz = elems[i].size();
      result = pos[0] + "," + pos[1] + "," + sz[0] + "," + sz[1];
      break;
    }
  } catch(e) {}
}
result;
''',
      ]);

      if (contentResult.exitCode != 0) {
        return NativeResult(
            success: false, message: 'Failed to get content bounds');
      }

      final parts = (contentResult.stdout as String).trim().split(',');
      if (parts.length != 4) {
        return NativeResult(
            success: false, message: 'Failed to parse content bounds');
      }

      final left = double.parse(parts[0]);
      final top = double.parse(parts[1]);
      final width = double.parse(parts[2]);
      final height = double.parse(parts[3]);
      final midY = top + height / 2;

      double startX, endX;
      if (gestureName == 'edge_swipe_left') {
        // Swipe from right edge to left
        startX = left + width - 5;
        endX = left + width * 0.3;
      } else {
        // Swipe from left edge to right
        startX = left + 5;
        endX = left + width * 0.7;
      }

      await Process.run('osascript', [
        '-e',
        '''
tell application "Simulator" to activate
delay 0.3
tell application "System Events"
    -- Perform drag from edge
    do shell script "cliclick dd:${startX.round()},${midY.round()} du:${endX.round()},${midY.round()}"
end tell
''',
      ]);

      return NativeResult(
          success: true, message: 'Performed gesture: $gestureName');
    }

    return NativeResult(
        success: false, message: 'Unknown gesture: $gestureName');
  }

  @override
  Future<NativeResult> pressKey(String key) async {
    // Use HID bridge if available
    if (await _hasBridge()) {
      final br = await _runBridge(['key', key]);
      if (br != null) {
        return NativeResult(
          success: br['success'] == true,
          message: br['message'] as String? ?? br['error'] as String?,
        );
      }
    }
    // Fallback: Map key names to osascript key codes or keystrokes
    String script;
    switch (key.toLowerCase()) {
      case 'enter':
      case 'return':
        script = 'tell application "System Events" to key code 36'; // Return
        break;
      case 'backspace':
        script = 'tell application "System Events" to key code 51'; // Delete
        break;
      case 'tab':
        script = 'tell application "System Events" to key code 48'; // Tab
        break;
      case 'escape':
        script = 'tell application "System Events" to key code 53'; // Escape
        break;
      case 'delete':
        script =
            'tell application "System Events" to key code 117'; // Forward Delete
        break;
      case 'space':
        script = 'tell application "System Events" to keystroke " "';
        break;
      case 'up':
        script = 'tell application "System Events" to key code 126'; // Up Arrow
        break;
      case 'down':
        script =
            'tell application "System Events" to key code 125'; // Down Arrow
        break;
      case 'left':
        script =
            'tell application "System Events" to key code 123'; // Left Arrow
        break;
      case 'right':
        script =
            'tell application "System Events" to key code 124'; // Right Arrow
        break;
      case 'home_key':
        script = 'tell application "System Events" to key code 115'; // Home
        break;
      case 'end_key':
        script = 'tell application "System Events" to key code 119'; // End
        break;
      case 'volume_up':
        final udid = await _getBootedSimulatorUdid();
        final r = await Process.run(
            'xcrun', ['simctl', 'ui', udid, 'increase_volume']);
        return NativeResult(
          success: r.exitCode == 0,
          message: r.exitCode == 0
              ? 'Pressed volume_up'
              : 'volume_up not supported via simctl',
        );
      case 'volume_down':
        final udid = await _getBootedSimulatorUdid();
        final r = await Process.run(
            'xcrun', ['simctl', 'ui', udid, 'decrease_volume']);
        return NativeResult(
          success: r.exitCode == 0,
          message: r.exitCode == 0
              ? 'Pressed volume_down'
              : 'volume_down not supported via simctl',
        );
      default:
        return NativeResult(success: false, message: 'Unknown key: $key');
    }

    await Process.run('osascript', [
      '-e',
      'tell application "Simulator" to activate',
    ]);
    await Future.delayed(const Duration(milliseconds: 200));

    final result = await Process.run('osascript', ['-e', script]);
    return NativeResult(
      success: result.exitCode == 0,
      message: result.exitCode == 0
          ? 'Pressed key: $key'
          : 'Key press failed: ${result.stderr}',
    );
  }

  @override
  Future<NativeResult> keyCombo(String keys) async {
    // Use HID bridge if available
    if (await _hasBridge()) {
      final br = await _runBridge(['key-combo', keys]);
      if (br != null) {
        return NativeResult(
          success: br['success'] == true,
          message: br['message'] as String? ?? br['error'] as String?,
        );
      }
    }
    // Fallback: Parse "cmd+a", "ctrl+shift+z", etc.
    final parts = keys.toLowerCase().split('+').map((s) => s.trim()).toList();
    if (parts.length < 2) {
      return NativeResult(
          success: false,
          message: 'Key combo requires at least 2 keys (e.g. "cmd+a")');
    }

    final key = parts.last;
    final modifiers = parts.sublist(0, parts.length - 1);

    final modifierStrs = <String>[];
    for (final mod in modifiers) {
      switch (mod) {
        case 'cmd':
        case 'command':
          modifierStrs.add('command down');
          break;
        case 'ctrl':
        case 'control':
          modifierStrs.add('control down');
          break;
        case 'shift':
          modifierStrs.add('shift down');
          break;
        case 'alt':
        case 'option':
          modifierStrs.add('option down');
          break;
        default:
          return NativeResult(
              success: false, message: 'Unknown modifier: $mod');
      }
    }

    final usingClause = modifierStrs.join(', ');

    await Process.run('osascript', [
      '-e',
      'tell application "Simulator" to activate',
    ]);
    await Future.delayed(const Duration(milliseconds: 200));

    String script;
    if (key.length == 1) {
      script =
          'tell application "System Events" to keystroke "$key" using {$usingClause}';
    } else {
      // Map named keys to key codes
      int? keyCode;
      switch (key) {
        case 'tab':
          keyCode = 48;
          break;
        case 'enter':
        case 'return':
          keyCode = 36;
          break;
        case 'delete':
        case 'backspace':
          keyCode = 51;
          break;
        case 'escape':
          keyCode = 53;
          break;
        case 'up':
          keyCode = 126;
          break;
        case 'down':
          keyCode = 125;
          break;
        case 'left':
          keyCode = 123;
          break;
        case 'right':
          keyCode = 124;
          break;
        default:
          return NativeResult(
              success: false, message: 'Unknown key in combo: $key');
      }
      script =
          'tell application "System Events" to key code $keyCode using {$usingClause}';
    }

    final result = await Process.run('osascript', ['-e', script]);
    return NativeResult(
      success: result.exitCode == 0,
      message: result.exitCode == 0
          ? 'Pressed key combo: $keys'
          : 'Key combo failed: ${result.stderr}',
    );
  }

  @override
  Future<NativeResult> hardwareButton(String button) async {
    // Use HID bridge if available
    if (await _hasBridge()) {
      final br = await _runBridge(['button', button]);
      if (br != null) {
        return NativeResult(
          success: br['success'] == true,
          message: br['message'] as String? ?? br['error'] as String?,
        );
      }
    }
    // Fallback: osascript/simctl
    final udid = await _getBootedSimulatorUdid();

    switch (button.toLowerCase()) {
      case 'home':
        // Use simctl spawn to send home button
        final r = await Process.run(
            'xcrun', ['simctl', 'spawn', udid, 'launchctl', 'reboot', 'apps']);
        // Fallback: use keyboard shortcut Cmd+Shift+H
        if (r.exitCode != 0) {
          await Process.run('osascript', [
            '-e',
            'tell application "Simulator" to activate',
          ]);
          await Future.delayed(const Duration(milliseconds: 200));
          final kr = await Process.run('osascript', [
            '-e',
            'tell application "System Events" to keystroke "h" using {command down, shift down}',
          ]);
          return NativeResult(
            success: kr.exitCode == 0,
            message:
                kr.exitCode == 0 ? 'Pressed home button' : 'Home button failed',
          );
        }
        return NativeResult(success: true, message: 'Pressed home button');

      case 'lock':
      case 'power':
        await Process.run('osascript', [
          '-e',
          'tell application "Simulator" to activate',
        ]);
        await Future.delayed(const Duration(milliseconds: 200));
        final r = await Process.run('osascript', [
          '-e',
          'tell application "System Events" to keystroke "l" using {command down}',
        ]);
        return NativeResult(
          success: r.exitCode == 0,
          message:
              r.exitCode == 0 ? 'Pressed lock button' : 'Lock button failed',
        );

      case 'siri':
        final r = await Process.run('xcrun', [
          'simctl',
          'spawn',
          udid,
          'notifyutil',
          '-p',
          'com.apple.SBActivateSiri'
        ]);
        // Fallback: long press home with keyboard
        if (r.exitCode != 0) {
          await Process.run('osascript', [
            '-e',
            'tell application "Simulator" to activate',
          ]);
          await Future.delayed(const Duration(milliseconds: 200));
          await Process.run('osascript', [
            '-e',
            'tell application "System Events" to keystroke "h" using {command down, shift down}',
          ]);
          await Future.delayed(const Duration(milliseconds: 2000));
        }
        return NativeResult(success: true, message: 'Triggered Siri');

      case 'volume_up':
        return pressKey('volume_up');

      case 'volume_down':
        return pressKey('volume_down');

      case 'app_switch':
        await Process.run('osascript', [
          '-e',
          'tell application "Simulator" to activate',
        ]);
        await Future.delayed(const Duration(milliseconds: 200));
        final r = await Process.run('osascript', [
          '-e',
          'tell application "System Events" to keystroke "h" using {command down, shift down}',
        ]);
        // Double press home for app switcher
        await Future.delayed(const Duration(milliseconds: 300));
        await Process.run('osascript', [
          '-e',
          'tell application "System Events" to keystroke "h" using {command down, shift down}',
        ]);
        return NativeResult(
          success: r.exitCode == 0,
          message:
              r.exitCode == 0 ? 'Opened app switcher' : 'App switcher failed',
        );

      case 'apple_pay':
      case 'apple-pay':
      case 'applepay':
        if (await _hasBridge()) {
          final br = await _runBridge(['button', 'apple-pay']);
          if (br != null) {
            return NativeResult(
              success: br['success'] == true,
              message: br['message'] as String? ?? br['error'] as String?,
            );
          }
        }
        return NativeResult(
            success: false, message: 'Apple Pay button requires fs-ios-bridge');

      case 'side':
      case 'side-button':
      case 'side_button':
        if (await _hasBridge()) {
          final br = await _runBridge(['button', 'side']);
          if (br != null) {
            return NativeResult(
              success: br['success'] == true,
              message: br['message'] as String? ?? br['error'] as String?,
            );
          }
        }
        return NativeResult(
            success: false, message: 'Side button requires fs-ios-bridge');

      default:
        return NativeResult(success: false, message: 'Unknown button: $button');
    }
  }

  // ===========================================================================
  // Video Recording (via simctl)
  // ===========================================================================

  Process? _videoProcess;
  String? _videoPath;

  /// Start recording the simulator screen to an MP4 file.
  Future<NativeResult> startVideoRecording({String? path}) async {
    if (_videoProcess != null) {
      return NativeResult(
          success: false, message: 'Video recording already in progress');
    }

    final udid = await _getBootedSimulatorUdid();
    _videoPath = path ??
        '${Directory.systemTemp.path}/fs_video_${DateTime.now().millisecondsSinceEpoch}.mp4';

    try {
      _videoProcess = await Process.start(
        'xcrun',
        ['simctl', 'io', udid, 'recordVideo', '--codec=h264', _videoPath!],
      );
      // Give it a moment to start
      await Future.delayed(const Duration(milliseconds: 500));
      return NativeResult(
        success: true,
        message: 'Video recording started',
        metadata: {'path': _videoPath},
      );
    } catch (e) {
      _videoProcess = null;
      return NativeResult(success: false, message: 'Failed to start: $e');
    }
  }

  /// Stop recording and return the video file path.
  Future<NativeResult> stopVideoRecording() async {
    if (_videoProcess == null) {
      return NativeResult(
          success: false, message: 'No video recording in progress');
    }

    // Send SIGINT to gracefully stop (simctl finalizes the MP4)
    _videoProcess!.kill(ProcessSignal.sigint);
    try {
      await _videoProcess!.exitCode.timeout(const Duration(seconds: 10));
    } catch (_) {
      _videoProcess!.kill();
    }
    _videoProcess = null;

    final path = _videoPath!;
    _videoPath = null;

    final file = File(path);
    if (await file.exists()) {
      final size = await file.length();
      return NativeResult(
        success: true,
        message: 'Video saved',
        metadata: {'path': path, 'size_bytes': size},
      );
    }
    return NativeResult(success: false, message: 'Video file not found: $path');
  }

  /// Capture a burst of screenshots as JPEG frames (lightweight streaming).
  /// Returns paths to captured frames.
  Future<NativeResult> captureFrames({
    int fps = 5,
    int durationMs = 3000,
    int quality = 80,
  }) async {
    final udid = await _getBootedSimulatorUdid();
    final interval = Duration(milliseconds: 1000 ~/ fps);
    final frames = <String>[];
    final stopwatch = Stopwatch()..start();

    while (stopwatch.elapsedMilliseconds < durationMs) {
      final framePath =
          '${Directory.systemTemp.path}/fs_frame_${frames.length}.jpg';
      final r = await Process.run('xcrun', [
        'simctl',
        'io',
        udid,
        'screenshot',
        '--type=jpeg',
        framePath,
      ]);
      if (r.exitCode == 0) frames.add(framePath);

      final elapsed = stopwatch.elapsed;
      final nextFrame = interval * (frames.length);
      if (nextFrame > elapsed) {
        await Future.delayed(nextFrame - elapsed);
      }
    }

    return NativeResult(
      success: true,
      message: 'Captured ${frames.length} frames at ${fps}fps',
      metadata: {
        'frames': frames,
        'count': frames.length,
        'fps': fps,
        'duration_ms': stopwatch.elapsedMilliseconds,
      },
    );
  }
}

// =============================================================================
// Android Emulator Driver
// =============================================================================

class AndroidEmulatorDriver extends NativeDriver {
  @override
  NativePlatform get platform => NativePlatform.androidEmulator;

  @override
  Future<NativeResult> screenshot({bool saveToFile = true}) async {
    final tempDir = Directory.systemTemp;
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final localPath = '${tempDir.path}/native_screenshot_$timestamp.png';
    const devicePath = '/sdcard/flutter_skill_screenshot.png';

    // Capture on device
    var result =
        await Process.run('adb', ['shell', 'screencap', '-p', devicePath]);
    if (result.exitCode != 0) {
      return NativeResult(
        success: false,
        message: 'Screenshot failed: ${result.stderr}',
      );
    }

    // Pull to local
    result = await Process.run('adb', ['pull', devicePath, localPath]);
    if (result.exitCode != 0) {
      return NativeResult(
        success: false,
        message: 'Failed to pull screenshot: ${result.stderr}',
      );
    }

    // Clean up device file
    await Process.run('adb', ['shell', 'rm', devicePath]);

    if (saveToFile) {
      return NativeResult(
        success: true,
        filePath: localPath,
        message: 'Native screenshot saved to $localPath',
      );
    }

    final bytes = await File(localPath).readAsBytes();
    final base64Image = base64.encode(bytes);
    await File(localPath).delete();
    return NativeResult(success: true, base64Image: base64Image);
  }

  @override
  Future<NativeResult> tap(double x, double y) async {
    final result = await Process.run(
      'adb',
      ['shell', 'input', 'tap', '${x.round()}', '${y.round()}'],
    );
    return NativeResult(
      success: result.exitCode == 0,
      message: result.exitCode == 0
          ? 'Tapped at (${x.round()}, ${y.round()})'
          : 'Tap failed: ${result.stderr}',
    );
  }

  @override
  Future<NativeResult> inputText(String text) async {
    // Escape special characters for adb shell input
    final escaped = text
        .replaceAll('\\', '\\\\')
        .replaceAll(' ', '%s')
        .replaceAll('&', '\\&')
        .replaceAll('<', '\\<')
        .replaceAll('>', '\\>')
        .replaceAll("'", "\\'")
        .replaceAll('"', '\\"');

    final result = await Process.run(
      'adb',
      ['shell', 'input', 'text', escaped],
    );
    return NativeResult(
      success: result.exitCode == 0,
      message: result.exitCode == 0
          ? 'Entered text: "$text"'
          : 'Text input failed: ${result.stderr}',
    );
  }

  @override
  Future<NativeResult> swipe(
    double startX,
    double startY,
    double endX,
    double endY, {
    int durationMs = 300,
  }) async {
    final result = await Process.run('adb', [
      'shell',
      'input',
      'swipe',
      '${startX.round()}',
      '${startY.round()}',
      '${endX.round()}',
      '${endY.round()}',
      '$durationMs',
    ]);
    return NativeResult(
      success: result.exitCode == 0,
      message: result.exitCode == 0
          ? 'Swiped from (${startX.round()},${startY.round()}) to (${endX.round()},${endY.round()})'
          : 'Swipe failed: ${result.stderr}',
    );
  }

  @override
  Future<Map<String, bool>> checkToolAvailability() async {
    return {
      'adb': await _isCommandAvailable('adb'),
    };
  }

  /// Get Android screen size via wm size
  Future<_Point?> _getScreenSize() async {
    final result = await Process.run('adb', ['shell', 'wm', 'size']);
    if (result.exitCode != 0) return null;
    // Output: "Physical size: 1080x1920"
    final match = RegExp(r'(\d+)x(\d+)').firstMatch(result.stdout as String);
    if (match == null) return null;
    return _Point(double.parse(match.group(1)!), double.parse(match.group(2)!));
  }

  @override
  Future<NativeResult> longPress(double x, double y,
      {int durationMs = 1000}) async {
    // Swipe to same point = long press
    final result = await Process.run('adb', [
      'shell',
      'input',
      'swipe',
      '${x.round()}',
      '${y.round()}',
      '${x.round()}',
      '${y.round()}',
      '$durationMs',
    ]);
    return NativeResult(
      success: result.exitCode == 0,
      message: result.exitCode == 0
          ? 'Long pressed at (${x.round()}, ${y.round()}) for ${durationMs}ms'
          : 'Long press failed: ${result.stderr}',
    );
  }

  @override
  Future<NativeResult> gesture(String gestureName) async {
    final size = await _getScreenSize();
    if (size == null) {
      return NativeResult(success: false, message: 'Failed to get screen size');
    }
    final w = size.x;
    final h = size.y;
    final midX = w / 2;
    final midY = h / 2;

    int startX, startY, endX, endY, duration;

    switch (gestureName) {
      case 'scroll_up':
        startX = midX.round();
        startY = (h * 0.7).round();
        endX = midX.round();
        endY = (h * 0.3).round();
        duration = 300;
        break;
      case 'scroll_down':
        startX = midX.round();
        startY = (h * 0.3).round();
        endX = midX.round();
        endY = (h * 0.7).round();
        duration = 300;
        break;
      case 'scroll_left':
        startX = (w * 0.8).round();
        startY = midY.round();
        endX = (w * 0.2).round();
        endY = midY.round();
        duration = 300;
        break;
      case 'scroll_right':
        startX = (w * 0.2).round();
        startY = midY.round();
        endX = (w * 0.8).round();
        endY = midY.round();
        duration = 300;
        break;
      case 'edge_swipe_left':
        startX = (w - 5).round();
        startY = midY.round();
        endX = (w * 0.3).round();
        endY = midY.round();
        duration = 200;
        break;
      case 'edge_swipe_right':
        startX = 5;
        startY = midY.round();
        endX = (w * 0.7).round();
        endY = midY.round();
        duration = 200;
        break;
      case 'pull_to_refresh':
        startX = midX.round();
        startY = (h * 0.2).round();
        endX = midX.round();
        endY = (h * 0.7).round();
        duration = 400;
        break;
      default:
        return NativeResult(
            success: false, message: 'Unknown gesture: $gestureName');
    }

    final result = await Process.run('adb', [
      'shell',
      'input',
      'swipe',
      '$startX',
      '$startY',
      '$endX',
      '$endY',
      '$duration',
    ]);
    return NativeResult(
      success: result.exitCode == 0,
      message: result.exitCode == 0
          ? 'Performed gesture: $gestureName'
          : 'Gesture failed: ${result.stderr}',
    );
  }

  @override
  Future<NativeResult> pressKey(String key) async {
    // Map key names to Android KEYCODE values
    int? keycode;
    switch (key.toLowerCase()) {
      case 'enter':
      case 'return':
        keycode = 66;
        break;
      case 'backspace':
        keycode = 67;
        break;
      case 'tab':
        keycode = 61;
        break;
      case 'escape':
        keycode = 111;
        break;
      case 'delete':
        keycode = 112;
        break;
      case 'space':
        keycode = 62;
        break;
      case 'up':
        keycode = 19;
        break;
      case 'down':
        keycode = 20;
        break;
      case 'left':
        keycode = 21;
        break;
      case 'right':
        keycode = 22;
        break;
      case 'home_key':
        keycode = 122;
        break; // KEYCODE_MOVE_HOME
      case 'end_key':
        keycode = 123;
        break; // KEYCODE_MOVE_END
      case 'volume_up':
        keycode = 24;
        break;
      case 'volume_down':
        keycode = 25;
        break;
      default:
        return NativeResult(success: false, message: 'Unknown key: $key');
    }

    final result =
        await Process.run('adb', ['shell', 'input', 'keyevent', '$keycode']);
    return NativeResult(
      success: result.exitCode == 0,
      message: result.exitCode == 0
          ? 'Pressed key: $key'
          : 'Key press failed: ${result.stderr}',
    );
  }

  @override
  Future<NativeResult> keyCombo(String keys) async {
    // Android has limited key combo support
    // For common combos, map to keyevent sequences
    final lower = keys.toLowerCase().replaceAll(' ', '');

    // Common combos
    switch (lower) {
      case 'ctrl+a':
        await Process.run(
            'adb', ['shell', 'input', 'keyevent', '113', '29']); // CTRL+A
        return NativeResult(success: true, message: 'Pressed key combo: $keys');
      case 'ctrl+c':
        await Process.run(
            'adb', ['shell', 'input', 'keyevent', '113', '31']); // CTRL+C
        return NativeResult(success: true, message: 'Pressed key combo: $keys');
      case 'ctrl+v':
        await Process.run(
            'adb', ['shell', 'input', 'keyevent', '113', '50']); // CTRL+V
        return NativeResult(success: true, message: 'Pressed key combo: $keys');
      case 'ctrl+x':
        await Process.run(
            'adb', ['shell', 'input', 'keyevent', '113', '52']); // CTRL+X
        return NativeResult(success: true, message: 'Pressed key combo: $keys');
      case 'ctrl+z':
        await Process.run(
            'adb', ['shell', 'input', 'keyevent', '113', '54']); // CTRL+Z
        return NativeResult(success: true, message: 'Pressed key combo: $keys');
      default:
        return NativeResult(
          success: false,
          message: 'Key combo "$keys" not supported on Android. '
              'Supported combos: ctrl+a, ctrl+c, ctrl+v, ctrl+x, ctrl+z',
        );
    }
  }

  @override
  Future<NativeResult> hardwareButton(String button) async {
    int? keycode;
    switch (button.toLowerCase()) {
      case 'home':
        keycode = 3;
        break;
      case 'lock':
      case 'power':
        keycode = 26;
        break;
      case 'volume_up':
        keycode = 24;
        break;
      case 'volume_down':
        keycode = 25;
        break;
      case 'app_switch':
        keycode = 187;
        break;
      case 'siri':
        // Android equivalent: Google Assistant
        keycode = 231; // KEYCODE_ASSIST
        break;
      default:
        return NativeResult(success: false, message: 'Unknown button: $button');
    }

    final result =
        await Process.run('adb', ['shell', 'input', 'keyevent', '$keycode']);
    return NativeResult(
      success: result.exitCode == 0,
      message: result.exitCode == 0
          ? 'Pressed button: $button'
          : 'Button press failed: ${result.stderr}',
    );
  }
}

// =============================================================================
// Shared Helpers
// =============================================================================

Future<bool> _isCommandAvailable(String command) async {
  try {
    final result = await Process.run('which', [command]);
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}
