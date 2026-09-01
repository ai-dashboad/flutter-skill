import 'dart:convert';
import 'dart:io';

/// A single named server instance entry stored in the registry.
class ServerEntry {
  final String id;
  final int port;
  final int pid;
  final String projectPath;
  final String deviceId;
  final String vmServiceUri;
  final DateTime startedAt;

  const ServerEntry({
    required this.id,
    required this.port,
    required this.pid,
    required this.projectPath,
    required this.deviceId,
    required this.vmServiceUri,
    required this.startedAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'port': port,
        'pid': pid,
        'projectPath': projectPath,
        'deviceId': deviceId,
        'vmServiceUri': vmServiceUri,
        'startedAt': startedAt.toIso8601String(),
      };

  factory ServerEntry.fromJson(Map<String, dynamic> json) => ServerEntry(
        id: json['id'] as String,
        port: json['port'] as int,
        pid: json['pid'] as int,
        projectPath: json['projectPath'] as String? ?? '',
        deviceId: json['deviceId'] as String? ?? '',
        vmServiceUri: json['vmServiceUri'] as String? ?? '',
        startedAt: json['startedAt'] != null
            ? DateTime.parse(json['startedAt'] as String)
            : DateTime.now(),
      );
}

/// Manages ~/.flutter_skill/servers/ registry of named server instances.
class ServerRegistry {
  static Directory get _registryDir {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '.';
    final sep = Platform.pathSeparator;
    return Directory('$home${sep}.flutter_skill${sep}servers');
  }

  static File _entryFile(String id) =>
      File('${_registryDir.path}${Platform.pathSeparator}$id.json');

  static File _sockFile(String id) =>
      File('${_registryDir.path}${Platform.pathSeparator}$id.sock');

  /// Write a server entry to disk.
  ///
  /// Throws [ArgumentError] if the entry id contains characters that could
  /// be used for path traversal attacks.
  ///
  /// Throws [StateError] if a server with the same id is already running
  /// (i.e. its PID is still alive). Stop the existing server first with
  /// `flutter_skill server stop --id=<id>` before registering a new one.
  static Future<void> register(ServerEntry entry) async {
    if (!RegExp(r'^[a-zA-Z0-9_\-]+$').hasMatch(entry.id)) {
      throw ArgumentError(
          'Invalid server id "${entry.id}". Only letters, numbers, hyphens, and underscores are allowed.');
    }

    // Prevent silent overwrites: check whether a live server already owns
    // this id before writing a new entry.
    final existing = await get(entry.id);
    if (existing != null && await _isPidAlive(existing.pid)) {
      throw StateError(
          'A server with id "${entry.id}" is already running on port ${existing.port} '
          '(PID ${existing.pid}). Stop it first: flutter_skill server stop --id=${entry.id}');
    }

    await _registryDir.create(recursive: true);
    await _entryFile(entry.id)
        .writeAsString(jsonEncode(entry.toJson()), flush: true);
  }

  /// Read a single server entry by ID. Returns null if not found or id is invalid.
  static Future<ServerEntry?> get(String id) async {
    if (!RegExp(r'^[a-zA-Z0-9_\-]+$').hasMatch(id)) return null;
    final file = _entryFile(id);
    if (!await file.exists()) return null;
    try {
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return ServerEntry.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  /// Return all registered entries. Does NOT delete stale entries.
  /// Call [prune] separately to clean up stale entries.
  static Future<List<ServerEntry>> listAll() async {
    if (!await _registryDir.exists()) return [];
    final entries = <ServerEntry>[];
    await for (final entity in _registryDir.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        final json =
            jsonDecode(await entity.readAsString()) as Map<String, dynamic>;
        entries.add(ServerEntry.fromJson(json));
      } catch (_) {
        // Skip malformed files.
      }
    }
    return entries;
  }

  /// Delete registry entries whose process is no longer alive.
  static Future<void> prune() async {
    if (!await _registryDir.exists()) return;
    await for (final entity in _registryDir.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        final json =
            jsonDecode(await entity.readAsString()) as Map<String, dynamic>;
        final entry = ServerEntry.fromJson(json);
        if (!await _isPidAlive(entry.pid)) {
          await entity.delete().catchError((_) => entity);
          final sock = _sockFile(entry.id);
          if (await sock.exists()) await sock.delete().catchError((_) => sock);
        }
      } catch (_) {
        // Skip malformed files.
      }
    }
  }

  /// Delete a server entry (and its Unix socket file if present).
  static Future<void> unregister(String id) async {
    final file = _entryFile(id);
    if (await file.exists()) await file.delete();
    final sock = _sockFile(id);
    if (await sock.exists()) await sock.delete();
  }

  /// Check whether the TCP port for the named server is accepting connections.
  static Future<bool> isAlive(String id) async {
    final entry = await get(id);
    if (entry == null) return false;
    return await _isTcpPortOpen('127.0.0.1', entry.port);
  }

  /// Unix socket path for a server id, or null on Windows or when id is invalid.
  static String? unixSocketPath(String id) {
    if (Platform.isWindows) return null;
    if (!RegExp(r'^[a-zA-Z0-9_\-]+$').hasMatch(id)) return null;
    return _sockFile(id).path;
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  static Future<bool> _isPidAlive(int pid) async {
    try {
      if (Platform.isWindows) {
        final result = await Process.run(
            'tasklist', ['/FI', 'PID eq $pid', '/NH'],
            runInShell: true);
        // Use word-boundary matching: PID column is space-padded in tasklist output.
        // A simple contains() would match PID 123 inside 1234.
        final output = result.stdout.toString();
        return output.split('\n').any((line) {
          final parts = line.trim().split(RegExp(r'\s+'));
          return parts.isNotEmpty && parts.any((p) => p == pid.toString());
        });
      } else {
        // kill -0 checks existence without sending a real signal.
        final result =
            await Process.run('kill', ['-0', pid.toString()], runInShell: true);
        return result.exitCode == 0;
      }
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _isTcpPortOpen(String host, int port) async {
    try {
      final socket = await Socket.connect(host, port,
          timeout: const Duration(milliseconds: 500));
      await socket.close();
      return true;
    } catch (_) {
      return false;
    }
  }
}
