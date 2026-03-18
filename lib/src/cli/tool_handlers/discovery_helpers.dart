part of '../server.dart';

extension _DiscoveryHelpers on FlutterMcpServer {
  Future<List<String>> _scanVmServices(int portStart, int portEnd) async {
    final vmServices = <String>[];
    final futures = <Future>[];

    for (var port = portStart; port <= portEnd; port++) {
      futures.add(_checkVmServicePort(port).then((uri) {
        if (uri != null) vmServices.add(uri);
      }));
    }

    await Future.wait(futures);
    return vmServices;
  }

  /// Check if a specific port has a VM Service
  Future<String?> _checkVmServicePort(int port) async {
    try {
      final socket = await Socket.connect('127.0.0.1', port,
          timeout: const Duration(milliseconds: 200));
      await socket.close();

      // Try to get VM Service info via HTTP
      final response = await http.get(
        Uri.parse('http://127.0.0.1:$port/'),
        headers: {'Accept': 'application/json'},
      ).timeout(const Duration(milliseconds: 500));

      if (response.statusCode == 200) {
        // Extract WebSocket URI from response
        final body = response.body;
        if (body.contains('ws://') || body.contains('Dart VM')) {
          // Construct WebSocket URI
          return 'ws://127.0.0.1:$port/ws';
        }
      }
    } catch (e) {
      // Port not available or not a VM Service
    }
    return null;
  }

  String _findAdb() {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'];
    final androidHome = Platform.environment['ANDROID_HOME'] ??
        Platform.environment['ANDROID_SDK_ROOT'] ??
        (home != null ? '$home/Library/Android/sdk' : null);
    if (androidHome != null) {
      final adbPath = '$androidHome/platform-tools/adb';
      if (File(adbPath).existsSync()) return adbPath;
    }
    return 'adb'; // fallback to PATH
  }

  Future<String> _detectSimulatorPlatform() async {
    // Check if active session is a bridge connection (non-Flutter)
    final client = _getClient({});
    if (client is BridgeDriver) {
      final fw = client.frameworkName.toLowerCase();
      if (['electron', 'tauri', 'web', 'kmp'].contains(fw)) return 'web';
      if (fw.contains('android') || fw == 'react-native' || fw == 'dotnet-maui')
        return 'android';
      if (fw.contains('ios')) return 'ios';
      return fw;
    }
    try {
      final result =
          await Process.run('xcrun', ['simctl', 'list', 'devices', 'booted']);
      if (result.exitCode == 0 && result.stdout.toString().contains('Booted')) {
        return 'ios';
      }
    } catch (_) {}
    return 'android';
  }

  String _generateTotp(String secret, int digits, int period) {
    final time = DateTime.now().millisecondsSinceEpoch ~/ 1000 ~/ period;
    final timeBytes = ByteData(8)..setInt64(0, time);
    final key = _base32Decode(secret);
    final hmac = Hmac(sha1, key);
    final hash = hmac.convert(timeBytes.buffer.asUint8List()).bytes;
    final offset = hash.last & 0x0f;
    final code = ((hash[offset] & 0x7f) << 24 |
            (hash[offset + 1] & 0xff) << 16 |
            (hash[offset + 2] & 0xff) << 8 |
            (hash[offset + 3] & 0xff)) %
        _pow(10, digits);
    return code.toString().padLeft(digits, '0');
  }

  int _pow(int base, int exp) {
    int result = 1;
    for (var i = 0; i < exp; i++) result *= base;
    return result;
  }

  List<int> _base32Decode(String input) {
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
    final cleaned = input.toUpperCase().replaceAll(RegExp(r'[^A-Z2-7]'), '');
    final output = <int>[];
    int buffer = 0, bitsLeft = 0;
    for (final c in cleaned.codeUnits) {
      final val = alphabet.indexOf(String.fromCharCode(c));
      if (val < 0) continue;
      buffer = (buffer << 5) | val;
      bitsLeft += 5;
      if (bitsLeft >= 8) {
        bitsLeft -= 8;
        output.add((buffer >> bitsLeft) & 0xff);
      }
    }
    return output;
  }
}
